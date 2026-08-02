#!/usr/bin/env node
/* 실제 browser에서 Pomerium -> Headlamp OIDC -> Kubernetes RBAC 경계를 검증한다. */
'use strict';

const crypto = require('crypto');
const { spawn } = require('child_process');
const fs = require('fs');
const https = require('https');
const net = require('net');

const HEADLAMP_URL = 'https://headlamp.imcherry5778.xyz';
const ISSUER_HOST = 'sso.imcherry5778.xyz';
const EXPECTED_ISSUER = `https://${ISSUER_HOST}/realms/platform`;
const APPROVED_HOSTS = [
  'headlamp.imcherry5778.xyz',
  'k3s-01.imcherry5778.xyz',
  ISSUER_HOST,
];
const CLUSTER = 'main';
const lastTotpWindow = new Map();

function headlampCookieScopeUrl() {
  return `${HEADLAMP_URL}/clusters/${CLUSTER}`;
}

function fixedIpv4Lookup(address) {
  if (!net.isIPv4(address)) fail('lookup address must be IPv4');
  return (_hostname, options, callback) => {
    if (options?.all) {
      callback(null, [{ address, family: 4 }]);
      return;
    }
    callback(null, address, 4);
  };
}

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || value === undefined) fail('invalid arguments');
    result[key.slice(2)] = value;
  }
  for (const key of ['connect-ip', 'username', 'password-file', 'totp-file', 'kind']) {
    if (!result[key]) fail(`missing --${key}`);
  }
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  if (!['daily', 'privileged', 'no-group'].includes(result.kind)) fail('kind must be daily, privileged, or no-group');
  if (result.kind !== 'no-group' && !result.group) fail('missing --group');
  return result;
}

function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_MODULE,
    'playwright',
    '/home/imcherry/.local/lib/node_modules/playwright',
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (_) {
      // 다음 명시적 후보를 확인한다.
    }
  }
  fail('Playwright module is unavailable');
}

function readPrivate(filePath) {
  const value = fs.readFileSync(filePath, 'utf8').trim();
  if (!value) fail('private input is empty');
  return value;
}

async function reserveTotpWindow(
  seedFile,
  nowSeconds = () => Math.floor(Date.now() / 1000),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
) {
  for (;;) {
    const now = nowSeconds();
    const windowIndex = Math.floor(now / 30);
    const remaining = 30 - (now % 30);
    const previousWindow = lastTotpWindow.get(seedFile) ?? -1;
    if (windowIndex > previousWindow && remaining >= 5) {
      lastTotpWindow.set(seedFile, windowIndex);
      return windowIndex;
    }
    await sleep((remaining + 1) * 1000);
  }
}

async function currentTotp(seedFile) {
  const windowIndex = await reserveTotpWindow(seedFile);
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const character of readPrivate(seedFile).toUpperCase().replace(/=+$/, '')) {
    const position = alphabet.indexOf(character);
    if (position < 0) fail('invalid TOTP seed');
    bits += position.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  }
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(windowIndex));
  const digest = crypto.createHmac('sha256', Buffer.from(bytes)).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const value = (digest.readUInt32BE(offset) & 0x7fffffff) % 1000000;
  return value.toString().padStart(6, '0');
}

async function completeKeycloakLogin(page, args) {
  await page.locator('input[name="username"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="username"]').fill(args.username);
  await page.locator('input[name="password"]').fill(readPrivate(args['password-file']));
  await page.locator('#kc-login').click();
  await page.locator('input[name="otp"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="otp"]').fill(await currentTotp(args['totp-file']));
  await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]')
    .first().click();
}

async function loginIfKeycloakForm(page, args) {
  const visible = await page.locator('input[name="username"]').isVisible({ timeout: 3000 }).catch(() => false);
  if (visible) await completeKeycloakLogin(page, args);
}

async function proxyRequest(page, path, init = {}) {
  return page.evaluate(async ({ pathArg, initArg }) => {
    const response = await fetch(`/clusters/main${pathArg}`, initArg);
    const text = await response.text();
    let body = null;
    try {
      body = JSON.parse(text);
    } catch (_) {
      // status-only assertion is enough for non-JSON Kubernetes streaming responses.
    }
    return { status: response.status, body };
  }, { pathArg: path, initArg: init });
}

function expectStatus(label, actual, expected) {
  if (actual !== expected) fail(`${label}: expected=${expected} actual=${actual}`);
  console.log(`${label}=${actual}`);
}

function decodeJwtClaims(token) {
  const pieces = token.split('.');
  if (pieces.length !== 3) fail('Headlamp auth cookie is not a JWT');
  const encoded = pieces[1].replace(/-/g, '+').replace(/_/g, '/');
  const padded = encoded.padEnd(encoded.length + ((4 - encoded.length % 4) % 4), '=');
  return JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
}

function audienceContains(audience, expected) {
  return (typeof audience === 'string' && audience === expected)
    || (Array.isArray(audience) && audience.includes(expected));
}

function requestWrongAudienceToken(args) {
  const secretFile = args['wrong-audience-secret-file'];
  if (!secretFile) return Promise.resolve('');
  const form = new URLSearchParams({
    grant_type: 'password',
    client_id: 'kc-verify',
    client_secret: readPrivate(secretFile),
    username: args.username,
    password: readPrivate(args['password-file']),
  });
  return currentTotp(args['totp-file']).then((code) => new Promise((resolve, reject) => {
    form.set('totp', code);
    const request = https.request({
      hostname: ISSUER_HOST,
      servername: ISSUER_HOST,
      port: 443,
      path: '/realms/platform/protocol/openid-connect/token',
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(form.toString()),
      },
      lookup: fixedIpv4Lookup(args['connect-ip']),
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        if (response.statusCode !== 200) return reject(new Error(`wrong-audience token HTTP ${response.statusCode}`));
        try {
          const token = JSON.parse(body).access_token;
          if (!token) fail('wrong-audience access token missing');
          resolve(token);
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on('error', reject);
    request.end(form.toString());
  }));
}

function remoteKubernetesStatus(token) {
  const k3sHost = process.env.K3S_HOST || 'rocky@k3s-01.imcherry5778.xyz';
  const knownHosts = process.env.K3S_SSH_KNOWN_HOSTS || '/home/imcherry/.ssh/known_hosts';
  if (!/^[a-z_][a-z0-9_-]*@[a-z0-9.-]+$/.test(k3sHost)) fail('invalid K3S_HOST');
  if (!knownHosts.startsWith('/') || /[\r\n]/.test(knownHosts)) fail('invalid K3S_SSH_KNOWN_HOSTS');
  const remoteCommand = [
    'set -eu',
    'umask 077',
    'header_file=$(mktemp /tmp/headlamp-02-wrong-audience.XXXXXX)',
    'trap \'rm -f "$header_file"\' EXIT HUP INT TERM',
    'IFS= read -r token',
    'printf \'Authorization: Bearer %s\\n\' "$token" >"$header_file"',
    'sudo -n /usr/bin/curl --silent --show-error --output /dev/null --write-out \'%{http_code}\' '
      + '--cacert /var/lib/rancher/k3s/server/tls/server-ca.crt '
      + '--header @"$header_file" https://127.0.0.1:6443/api/v1/namespaces',
  ].join('; ');

  return new Promise((resolve, reject) => {
    const child = spawn('ssh', [
      '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=yes',
      '-o', `UserKnownHostsFile=${knownHosts}`,
      k3sHost,
      remoteCommand,
    ], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (stdout.length > 16) child.kill();
    });
    child.stderr.resume();
    child.on('error', () => reject(new Error('wrong-audience SSH execution failed')));
    child.on('close', (code) => {
      const status = stdout.trim();
      if (code !== 0 || !/^\d{3}$/.test(status)) {
        reject(new Error(`wrong-audience Kubernetes request failed: ssh=${code}`));
        return;
      }
      resolve(Number(status));
    });
    child.stdin.end(`${token}\n`);
  });
}

async function verifyWrongAudienceDeny(args) {
  if (args['wrong-audience-secret-file']) {
    const waitSeconds = 31 - (Math.floor(Date.now() / 1000) % 30);
    console.log(`WRONG_AUDIENCE_TOTP_WAIT=${waitSeconds}s`);
    await new Promise((resolve) => setTimeout(resolve, waitSeconds * 1000));
  }
  let token = await requestWrongAudienceToken(args);
  if (!token) return;
  try {
    const status = await remoteKubernetesStatus(token);
    expectStatus('DENY_WRONG_AUDIENCE', status, 401);
  } finally {
    token = '';
  }
}

async function headlampToken(context, args) {
  const cookies = await context.cookies(headlampCookieScopeUrl());
  const pieces = cookies
    .filter((cookie) => /^headlamp-auth-main\.\d+$/.test(cookie.name))
    .sort((left, right) => Number(left.name.split('.').pop()) - Number(right.name.split('.').pop()))
    .map((cookie) => cookie.value);
  if (!pieces.length) fail('Headlamp OIDC HttpOnly cookie is missing');
  const token = pieces.join('');
  const claims = decodeJwtClaims(token);
  if (claims.iss !== EXPECTED_ISSUER) fail('Headlamp ID token issuer mismatch');
  if (!audienceContains(claims.aud, 'headlamp')) fail('Headlamp ID token audience mismatch');
  if (claims.preferred_username !== args.username) fail('Headlamp ID token username mismatch');
  if (!Array.isArray(claims.groups) || !claims.groups.includes(args.group)) fail('Headlamp ID token groups mismatch');
  if (!Number.isInteger(claims.iat) || !Number.isInteger(claims.exp) || claims.exp <= Math.floor(Date.now() / 1000)) {
    fail('Headlamp ID token TTL is invalid');
  }
  console.log(
    `OIDC_CLAIMS=issuer:ok,aud:headlamp,username:${claims.preferred_username},groups:${claims.groups.join(',')},ttl:${claims.exp - Math.floor(Date.now() / 1000)}s`,
  );
  return token;
}

async function verifyPrivilegedExec(page, podName) {
  if (!/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(podName)) fail('unexpected Dashy Pod name');
  const result = await page.evaluate(async ({ name }) => new Promise((resolve) => {
    const query = new URLSearchParams({
      container: 'dashy', command: 'node', stdout: 'true', stderr: 'true', tty: 'false',
    });
    query.append('command', '-e');
    query.append('command', 'process.exit(0)');
    const socket = new WebSocket(
      `wss://headlamp.imcherry5778.xyz/clusters/main/api/v1/namespaces/pomerium/pods/${name}/exec?${query.toString()}`,
      'v5.channel.k8s.io',
    );
    socket.binaryType = 'arraybuffer';
    let opened = false;
    let successfulStatus = false;
    const timer = window.setTimeout(() => {
      socket.close();
      resolve({ opened, successfulStatus, timeout: true });
    }, 20000);
    socket.onopen = () => { opened = true; };
    socket.onmessage = async (event) => {
      const buffer = event.data instanceof Blob
        ? await event.data.arrayBuffer()
        : event.data;
      const bytes = new Uint8Array(buffer);
      if (bytes[0] === 3) {
        try {
          successfulStatus = JSON.parse(new TextDecoder().decode(bytes.slice(1))).status === 'Success';
        } catch (_) {
          successfulStatus = false;
        }
      }
    };
    socket.onerror = () => {
      window.clearTimeout(timer);
      resolve({ opened, successfulStatus, error: true });
    };
    socket.onclose = () => {
      window.clearTimeout(timer);
      resolve({ opened, successfulStatus, timeout: false });
    };
  }), { name: podName });
  if (!result.opened || !result.successfulStatus || result.timeout || result.error) {
    fail('privileged Headlamp proxy exec did not complete successfully');
  }
  console.log('ALLOW_PRIVILEGED_EXEC=websocket-success');
}

async function verifyApiIdentity(page, args) {
  const review = await proxyRequest(page, '/apis/authentication.k8s.io/v1/selfsubjectreviews', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ apiVersion: 'authentication.k8s.io/v1', kind: 'SelfSubjectReview' }),
  });
  expectStatus('API_SELF_SUBJECT_REVIEW', review.status, 201);
  const userInfo = review.body?.status?.userInfo;
  if (userInfo?.username !== `oidc:${args.username}` || !Array.isArray(userInfo.groups)
      || !userInfo.groups.includes(`oidc:${args.group}`)) {
    fail('Kubernetes API did not report the expected OIDC identity');
  }
  console.log(`API_USER=oidc:${args.username},group:oidc:${args.group}`);
}

async function getPods(page, namespace) {
  const response = await proxyRequest(page, `/api/v1/namespaces/${namespace}/pods`);
  expectStatus(`ALLOW_PODS_${namespace.toUpperCase().replace(/-/g, '_')}`, response.status, 200);
  if (!Array.isArray(response.body?.items) || !response.body.items.length) fail(`Pod list is empty: ${namespace}`);
  return response.body.items;
}

async function verifyCommonReadAndCriticalDeny(page, args) {
  const namespaces = await proxyRequest(page, '/api/v1/namespaces');
  expectStatus('ALLOW_NAMESPACES', namespaces.status, 200);
  const headlampPods = await getPods(page, 'headlamp');
  const headlampPod = headlampPods.find((pod) => pod.metadata?.labels?.['app.kubernetes.io/name'] === 'headlamp');
  if (!headlampPod?.metadata?.name) fail('Headlamp Pod was not found');
  const logs = await proxyRequest(page, `/api/v1/namespaces/headlamp/pods/${headlampPod.metadata.name}/log?tailLines=1`);
  expectStatus('ALLOW_POD_LOG', logs.status, 200);

  const denyRequests = [
    ['DENY_SECRETS', '/api/v1/namespaces/headlamp/secrets', {}],
    ['DENY_CRD', '/apis/apiextensions.k8s.io/v1/customresourcedefinitions', {}],
    ['DENY_WEBHOOK', '/apis/admissionregistration.k8s.io/v1/validatingwebhookconfigurations', {}],
    ['DENY_TOKEN_REQUEST', '/api/v1/namespaces/headlamp/serviceaccounts/headlamp/token', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiVersion: 'authentication.k8s.io/v1', kind: 'TokenRequest', spec: { expirationSeconds: 600 } }),
    }],
    ['DENY_RBAC_WRITE', '/apis/rbac.authorization.k8s.io/v1/namespaces/headlamp/roles?dryRun=All', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiVersion: 'rbac.authorization.k8s.io/v1', kind: 'Role', metadata: { name: 'headlamp-02-denied', namespace: 'headlamp' }, rules: [] }),
    }],
    ['DENY_CSR_APPROVE', '/apis/certificates.k8s.io/v1/certificatesigningrequests/headlamp-02-absent/approval?dryRun=All', {
      method: 'PATCH', headers: { 'Content-Type': 'application/merge-patch+json' }, body: JSON.stringify({ status: { conditions: [] } }),
    }],
  ];
  for (const [label, path, init] of denyRequests) {
    const response = await proxyRequest(page, path, init);
    expectStatus(label, response.status, 403);
  }
  const nodes = await proxyRequest(page, '/api/v1/nodes');
  expectStatus('ALLOW_NODES', nodes.status, 200);
  const node = nodes.body?.items?.[0]?.metadata?.name;
  if (!node) fail('Node name is missing');
  const nodePatch = await proxyRequest(page, `/api/v1/nodes/${node}?dryRun=All`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/merge-patch+json' },
    body: JSON.stringify({ metadata: { labels: { 'headlamp-02.invalid': 'true' } } }),
  });
  expectStatus('DENY_NODE_WRITE', nodePatch.status, 403);

  const deniedChange = await proxyRequest(page, '/api/v1/namespaces/headlamp-rbac-test/configmaps?dryRun=All', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ apiVersion: 'v1', kind: 'ConfigMap', metadata: { name: 'headlamp-02-denied', namespace: 'headlamp-rbac-test' }, data: { probe: 'deny' } }),
  });
  if (args.kind === 'daily') expectStatus('DENY_DAILY_CHANGE', deniedChange.status, 403);
  else if (deniedChange.status !== 201) fail(`privileged dry-run change expected=201 actual=${deniedChange.status}`);
}

async function verifyDaily(page, dashyPod) {
  const exec = await proxyRequest(page,
    `/api/v1/namespaces/pomerium/pods/${dashyPod}/exec?container=dashy&command=node&command=-e&command=process.exit%280%29&stdout=true&stderr=true`,
    { method: 'POST' });
  expectStatus('DENY_DAILY_EXEC', exec.status, 403);
}

async function verifyNoGroupPomeriumDeny(page) {
  const status = await page.evaluate(async () => {
    const response = await fetch('/', { redirect: 'manual' });
    return response.status;
  });
  expectStatus('DENY_NO_GROUP_POMERIUM_ROUTE', status, 403);
}

async function verifyNoGroupClaims(args) {
  const waitSeconds = 31 - (Math.floor(Date.now() / 1000) % 30);
  console.log(`NO_GROUP_CLAIMS_TOTP_WAIT=${waitSeconds}s`);
  await new Promise((resolve) => setTimeout(resolve, waitSeconds * 1000));
  let token = await requestWrongAudienceToken(args);
  if (!token) fail('no-group claim verification needs wrong-audience client input');
  try {
    const claims = decodeJwtClaims(token);
    if (claims.iss !== EXPECTED_ISSUER || !Array.isArray(claims.groups) || claims.groups.length !== 0) {
      fail('no-group identity did not produce an empty groups array');
    }
    console.log('NO_GROUP_CLAIMS=issuer:ok,groups:empty');
  } finally {
    token = '';
  }
}

async function verifyPrivilegedMutation(page) {
  const name = `headlamp-02-verify-${crypto.randomUUID().slice(0, 8)}`;
  let created = false;
  try {
    const create = await proxyRequest(page, '/api/v1/namespaces/headlamp-rbac-test/configmaps', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiVersion: 'v1', kind: 'ConfigMap', metadata: { name, namespace: 'headlamp-rbac-test' }, data: { phase: 'create' } }),
    });
    expectStatus('ALLOW_PRIVILEGED_CREATE', create.status, 201);
    created = true;
    const update = await proxyRequest(page, `/api/v1/namespaces/headlamp-rbac-test/configmaps/${name}`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiVersion: 'v1', kind: 'ConfigMap', metadata: { name, namespace: 'headlamp-rbac-test', resourceVersion: create.body?.metadata?.resourceVersion }, data: { phase: 'update' } }),
    });
    expectStatus('ALLOW_PRIVILEGED_UPDATE', update.status, 200);
    const patch = await proxyRequest(page, `/api/v1/namespaces/headlamp-rbac-test/configmaps/${name}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/merge-patch+json' }, body: JSON.stringify({ data: { phase: 'patch' } }),
    });
    expectStatus('ALLOW_PRIVILEGED_PATCH', patch.status, 200);
    const remove = await proxyRequest(page, `/api/v1/namespaces/headlamp-rbac-test/configmaps/${name}`, { method: 'DELETE' });
    expectStatus('ALLOW_PRIVILEGED_DELETE', remove.status, 200);
    created = false;
  } finally {
    if (created) {
      const cleanup = await proxyRequest(page, `/api/v1/namespaces/headlamp-rbac-test/configmaps/${name}`, { method: 'DELETE' });
      if (![200, 404].includes(cleanup.status)) fail(`ConfigMap cleanup failed: ${cleanup.status}`);
    }
  }
  console.log('PRIVILEGED_CONFIGMAP_CLEANUP=0');
}

async function verifySessionExpiry(context, page, args) {
  const cookies = await context.cookies(headlampCookieScopeUrl());
  const expiry = cookies
    .filter((cookie) => /^headlamp-auth-main\.\d+$/.test(cookie.name) && Number.isFinite(cookie.expires))
    .map((cookie) => cookie.expires)
    .sort((left, right) => right - left)[0];
  if (!expiry) fail('Headlamp session expiry cookie is missing');
  let remaining = expiry - Math.floor(Date.now() / 1000) + 2;
  if (remaining < 1 || remaining > 660) fail(`unexpected Headlamp session wait: ${remaining}s`);
  await page.close();
  while (remaining > 0) {
    const interval = Math.min(30, remaining);
    console.log(`HEADLAMP_SESSION_EXPIRY_REMAINING<=${remaining}s`);
    await new Promise((resolve) => setTimeout(resolve, interval * 1000));
    remaining -= interval;
  }

  const renewed = await context.newPage();
  try {
    await renewed.goto(`${HEADLAMP_URL}/c/${CLUSTER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await renewed.waitForURL(/https:\/\/(headlamp|sso|k3s-01)\.imcherry5778\.xyz\/.*/, { timeout: 30000 });
    await loginIfKeycloakForm(renewed, args);
    await renewed.waitForURL(/https:\/\/headlamp\.imcherry5778\.xyz\/.*/, { timeout: 45000 });
    const signIn = renewed.getByRole('button', { name: 'Sign In', exact: true });
    await signIn.waitFor({ state: 'visible', timeout: 45000 });
    const [popup] = await Promise.all([context.waitForEvent('page'), signIn.click()]);
    await popup.waitForLoadState('domcontentloaded', { timeout: 30000 });
    await loginIfKeycloakForm(popup, args);
    await renewed.waitForFunction(async () => {
      const response = await fetch('/clusters/main/api/v1/namespaces');
      return response.status === 200;
    }, undefined, { timeout: 45000 });
    console.log('HEADLAMP_SESSION_EXPIRY_REAUTH=ok');
  } finally {
    await renewed.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { chromium } = loadPlaywright();
  const mapRules = APPROVED_HOSTS.map((host) => `MAP ${host} ${args['connect-ip']}`).join(',');
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome',
    headless: true,
    args: [`--host-resolver-rules=${mapRules}`, '--no-proxy-server'],
  });
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(HEADLAMP_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForURL(/https:\/\/(headlamp|sso|k3s-01)\.imcherry5778\.xyz\/.*/, { timeout: 30000 });
    await loginIfKeycloakForm(page, args);
    await page.waitForURL(/https:\/\/headlamp\.imcherry5778\.xyz\/.*/, { timeout: 45000 });

    if (args.kind === 'no-group') {
      await verifyNoGroupClaims(args);
      await verifyNoGroupPomeriumDeny(page);
      await context.close();
      console.log('HEADLAMP_BROWSER_RBAC=ok,kind:no-group');
      return;
    }

    console.log('POMERIUM_ROUTE_ALLOW=ok');

    await page.goto(`${HEADLAMP_URL}/c/${CLUSTER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    const signIn = page.getByRole('button', { name: 'Sign In', exact: true });
    await signIn.waitFor({ state: 'visible', timeout: 45000 });
    let callbackSeen = false;
    const callbackRequest = (request) => {
      if (request.isNavigationRequest() && request.url().startsWith(`${HEADLAMP_URL}/oidc-callback`)) {
        callbackSeen = true;
      }
    };
    context.on('request', callbackRequest);
    const [popup] = await Promise.all([
      context.waitForEvent('page'),
      signIn.click(),
    ]);
    await popup.waitForLoadState('domcontentloaded', { timeout: 30000 });
    await loginIfKeycloakForm(popup, args);
    await page.waitForFunction(async () => {
      const response = await fetch('/clusters/main/me');
      return response.status === 200;
    }, undefined, { timeout: 45000 });
    context.off('request', callbackRequest);
    if (!callbackSeen) fail('Headlamp HTTPS OIDC callback was not observed');
    console.log('HEADLAMP_CALLBACK_HTTPS=ok');

    await headlampToken(context, args);
    await verifyApiIdentity(page, args);
    await verifyCommonReadAndCriticalDeny(page, args);
    await verifyWrongAudienceDeny(args);
    const dashyPods = await getPods(page, 'pomerium');
    const dashy = dashyPods.find((pod) => pod.metadata?.labels?.['app.kubernetes.io/name'] === 'dashy');
    if (!dashy?.metadata?.name) fail('Dashy Pod was not found');

    if (args.kind === 'daily') {
      await verifyDaily(page, dashy.metadata.name);
    } else {
      await verifyPrivilegedExec(page, dashy.metadata.name);
      await verifyPrivilegedMutation(page);
    }
    if (args['check-expiry'] === 'true') await verifySessionExpiry(context, page, args);
    await context.close();
    console.log(`HEADLAMP_BROWSER_RBAC=ok,kind:${args.kind}`);
  } finally {
    await browser.close();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`headlamp-browser-verify failed: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  fixedIpv4Lookup,
  headlampCookieScopeUrl,
  headlampToken,
  reserveTotpWindow,
};
