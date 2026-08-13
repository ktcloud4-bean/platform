#!/usr/bin/env node
/* 실제 Keycloak/Pomerium/AWX session으로 credential과 approval RBAC를 판정한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');

const AWX_URL = 'https://awx.imcherry5778.xyz';
const APPROVED_HOSTS = ['awx.imcherry5778.xyz', 'k3s-01.imcherry5778.xyz', 'sso.imcherry5778.xyz'];
const lastTotpWindow = new Map();

function fail(message) { throw new Error(message); }
function readPrivate(path) {
  const value = fs.readFileSync(path, 'utf8').trim();
  if (!value) fail('private input is empty');
  return value;
}
function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || value === undefined) fail('invalid arguments');
    result[key.slice(2)] = value;
  }
  for (const key of ['connect-ip', 'daily-username', 'privileged-username',
    'daily-password-file', 'daily-totp-file',
    'privileged-password-file', 'privileged-totp-file', 'object-file', 'secret-env-file']) {
    if (!result[key]) fail(`missing --${key}`);
  }
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  return result;
}
function loadPlaywright() {
  for (const candidate of [process.env.PLAYWRIGHT_MODULE, 'playwright',
    '/home/imcherry/.local/lib/node_modules/playwright'].filter(Boolean)) {
    try { return require(candidate); } catch (_) { /* 다음 후보 */ }
  }
  fail('Playwright module is unavailable');
}
async function currentTotp(seedFile) {
  for (;;) {
    const now = Math.floor(Date.now() / 1000);
    const windowIndex = Math.floor(now / 30);
    const remaining = 30 - (now % 30);
    if (windowIndex > (lastTotpWindow.get(seedFile) ?? -1) && remaining >= 5) {
      lastTotpWindow.set(seedFile, windowIndex);
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
      return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
    }
    await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1000));
  }
}
async function keycloakLogin(page, username, passwordFile, totpFile) {
  await page.locator('input[name="username"]').waitFor({state: 'visible', timeout: 30000});
  await page.locator('input[name="username"]').fill(username);
  await page.locator('input[name="password"]').fill(readPrivate(passwordFile));
  await page.locator('#kc-login').click();
  await page.waitForFunction(() => Boolean(
    document.querySelector('input[name="otp"]') ||
    document.querySelector('.alert-error, .pf-v5-c-alert, #input-error, .kc-feedback-text') ||
    location.hostname === 'awx.imcherry5778.xyz'
  ), null, {timeout: 30000});
  if (new URL(page.url()).hostname === 'awx.imcherry5778.xyz') return;
  if (!await page.locator('input[name="otp"]').isVisible()) {
    const state = await page.evaluate(() => ({
      url: location.href,
      inputs: [...document.querySelectorAll('input')].map((input) => input.name || input.type || 'unnamed'),
      errors: [...document.querySelectorAll('.alert-error, .pf-v5-c-alert, #input-error, .kc-feedback-text')]
        .map((element) => element.textContent.trim()).filter(Boolean),
    }));
    fail(`Keycloak password 단계가 OTP로 전환되지 않았다: ${JSON.stringify(state)}`);
  }
  await page.locator('input[name="otp"]').fill(await currentTotp(totpFile));
  await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]').first().click();
  await page.waitForFunction(() => location.hostname !== 'sso.imcherry5778.xyz' || Boolean(
    document.querySelector('.alert-error, #input-error')
  ), null, {timeout: 30000});
  if (new URL(page.url()).hostname === 'sso.imcherry5778.xyz') {
    const state = await page.evaluate(() => ({
      inputs: [...document.querySelectorAll('input')].map((input) => input.name || input.type || 'unnamed'),
      errors: [...document.querySelectorAll('.alert-error, #input-error')]
        .map((element) => element.textContent.trim()).filter(Boolean),
    }));
    fail(`Keycloak TOTP가 거부되었거나 재사용됐다: ${JSON.stringify(state)}`);
  }
}
async function api(page, method, path, body, expected) {
  const response = await page.evaluate(async ({methodArg, pathArg, bodyArg}) => {
    const csrf = document.cookie.split('; ').find((entry) => entry.startsWith('csrftoken='))?.split('=')[1] || '';
    const result = await fetch(pathArg, {
      method: methodArg,
      credentials: 'same-origin',
      headers: {'Content-Type': 'application/json', 'X-CSRFToken': decodeURIComponent(csrf)},
      body: bodyArg === null ? undefined : JSON.stringify(bodyArg),
    });
    const text = await result.text();
    let parsed = {};
    try { parsed = JSON.parse(text); } catch (_) { /* empty response */ }
    return {status: result.status, body: parsed};
  }, {methodArg: method, pathArg: path, bodyArg: body ?? null});
  if (!expected.includes(response.status)) {
    fail(`${method} ${path}: HTTP ${response.status}, expected ${expected.join('/')}`);
  }
  return response;
}
async function awxLogin(browser, connectIp, username, passwordFile, totpFile) {
  const context = await browser.newContext({ignoreHTTPSErrors: false});
  const page = await context.newPage();
  await page.goto(AWX_URL, {waitUntil: 'domcontentloaded', timeout: 60000});
  if (new URL(page.url()).hostname === 'sso.imcherry5778.xyz') {
    await keycloakLogin(page, username, passwordFile, totpFile);
  }
  await page.waitForURL((url) => url.hostname === 'awx.imcherry5778.xyz', {timeout: 60000});
  const oidcLink = page.locator('a[href*="/sso/login/oidc/"]').first();
  if (await oidcLink.isVisible({timeout: 15000}).catch(() => false)) {
    await oidcLink.click();
  } else {
    await page.goto(`${AWX_URL}/sso/login/oidc/`, {waitUntil: 'domcontentloaded', timeout: 60000});
  }
  if (new URL(page.url()).hostname === 'sso.imcherry5778.xyz'
      && await page.locator('input[name="username"]').isVisible({timeout: 2000}).catch(() => false)) {
    await keycloakLogin(page, username, passwordFile, totpFile);
  }
  await page.waitForURL((url) => url.hostname === 'awx.imcherry5778.xyz', {timeout: 60000});
  const me = await api(page, 'GET', '/api/v2/me/', null, [200]);
  if (me.body.count !== 1 || me.body.results[0].username !== username) {
    fail(`AWX OIDC identity mismatch for ${username}`);
  }
  return {context, page};
}
async function waitJob(page, kind, id, expected) {
  for (let attempt = 0; attempt < 240; attempt += 1) {
    const response = await api(page, 'GET', `/api/v2/${kind}/${id}/`, null, [200]);
    if (response.body.status === expected) return response.body;
    if (['failed', 'error', 'canceled'].includes(response.body.status)) {
      fail(`${kind}/${id} ended ${response.body.status}, expected ${expected}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  fail(`${kind}/${id} timeout`);
}
function loadSecretValues(path) {
  return fs.readFileSync(path, 'utf8').split(/\r?\n/).filter((line) => line && !line.startsWith('#'))
    .map((line) => line.slice(line.indexOf('=') + 1)).filter((value) => value.length >= 20);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const objects = JSON.parse(fs.readFileSync(args['object-file'], 'utf8'));
  const {chromium} = loadPlaywright();
  const rules = APPROVED_HOSTS.map((host) => `MAP ${host} ${args['connect-ip']}`).join(',');
  const browser = await chromium.launch({headless: true, args: [`--host-resolver-rules=${rules}`, '--no-proxy-server']});
  try {
    const operator = await awxLogin(browser, args['connect-ip'], args['daily-username'],
      args['daily-password-file'], args['daily-totp-file']);
    const approver = await awxLogin(browser, args['connect-ip'], args['privileged-username'],
      args['privileged-password-file'], args['privileged-totp-file']);

    await api(operator.page, 'GET', `/api/v2/credentials/${objects.allowed_credential}/`, null, [200]);
    await api(operator.page, 'GET', `/api/v2/credentials/${objects.denied_credential}/`, null, [403, 404]);
    const checkLaunch = await api(operator.page, 'POST', `/api/v2/job_templates/${objects.check_template}/launch/`, {}, [201]);
    const checkId = checkLaunch.body.job || checkLaunch.body.id;
    await waitJob(operator.page, 'jobs', checkId, 'successful');
    await api(operator.page, 'POST', `/api/v2/job_templates/${objects.denied_template}/launch/`, {}, [403]);
    await api(operator.page, 'POST', `/api/v2/job_templates/${objects.apply_template}/launch/`, {}, [403]);
    await api(approver.page, 'POST', `/api/v2/job_templates/${objects.check_template}/launch/`, {}, [403]);
    await api(approver.page, 'POST', `/api/v2/workflow_job_templates/${objects.workflow}/launch/`, {}, [403]);
    await api(approver.page, 'PATCH', `/api/v2/teams/${objects.operators_team}/`,
      {name: 'AWX Operators'}, [403]);

    const stdout = await api(operator.page, 'GET', `/api/v2/jobs/${checkId}/stdout/?format=json`, null, [200]);
    const stdoutText = JSON.stringify(stdout.body);
    for (const secret of loadSecretValues(args['secret-env-file'])) {
      if (stdoutText.includes(secret)) fail('job stdout contains a secret literal');
    }
    console.log(`CREDENTIAL_COMPARE_AT=${new Date().toISOString()} allowed_job=${checkId} denied_template=403 denied_credential=403`);

    const workflowLaunch = await api(operator.page, 'POST', `/api/v2/workflow_job_templates/${objects.workflow}/launch/`, {}, [201]);
    const workflowId = workflowLaunch.body.workflow_job || workflowLaunch.body.id;
    let approvalId = null;
    let applyStartedBeforeApproval = false;
    for (let attempt = 0; attempt < 120; attempt += 1) {
      const nodes = await api(operator.page, 'GET', `/api/v2/workflow_jobs/${workflowId}/workflow_nodes/`, null, [200]);
      for (const node of nodes.body.results) {
        const job = node.summary_fields?.job;
        if (job?.type === 'workflow_approval' && job.status === 'pending') approvalId = job.id;
        if (node.identifier === 'approved-apply' && job && !['new', 'never updated'].includes(job.status)) {
          applyStartedBeforeApproval = true;
        }
      }
      if (approvalId) break;
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    if (!approvalId || applyStartedBeforeApproval) fail('apply started before approval or approval did not pend');
    await api(operator.page, 'POST', `/api/v2/workflow_approvals/${approvalId}/approve/`, {}, [403]);
    const before = new Date().toISOString();
    await api(approver.page, 'POST', `/api/v2/workflow_approvals/${approvalId}/approve/`, {}, [200, 204]);
    await waitJob(operator.page, 'workflow_jobs', workflowId, 'successful');
    const afterNodes = await api(operator.page, 'GET', `/api/v2/workflow_jobs/${workflowId}/workflow_nodes/`, null, [200]);
    const applyNode = afterNodes.body.results.find((node) => node.identifier === 'approved-apply');
    if (applyNode?.summary_fields?.job?.status !== 'successful') fail('approved apply node did not succeed');
    console.log(`APPROVAL_BOUNDARY before=${before} operator_approve=403 after=successful workflow=${workflowId}`);
    console.log(`OIDC_RBAC ${args['daily-username']}=AWX_Operators ${args['privileged-username']}=AWX_Approvers`);
    console.log('FORBIDDEN_RBAC daily_apply=403 daily_approval=403 privileged_execute=403 privileged_permission_manage=403');

    await operator.context.close();
    await approver.context.close();
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`AWX-01 browser verification failed: ${error.message}`);
  process.exit(1);
});
