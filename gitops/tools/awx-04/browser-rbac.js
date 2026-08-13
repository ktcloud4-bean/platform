#!/usr/bin/env node
/* AWX-04: 실제 OIDC browser session으로 read-only SCM RBAC만 판정한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');
const AWX_URL = 'https://awx.imcherry5778.xyz';

function fail(message) { throw new Error(message); }
function privateValue(path) {
  const value = fs.readFileSync(path, 'utf8').trim();
  if (!value) fail('empty private input');
  return value;
}
function args(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i]?.startsWith('--') || argv[i + 1] === undefined) fail('invalid arguments');
    result[argv[i].slice(2)] = argv[i + 1];
  }
  for (const name of ['connect-ip', 'username', 'password-file', 'totp-file', 'object-file']) {
    if (!result[name]) fail(`missing --${name}`);
  }
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  return result;
}
function playwright() {
  for (const candidate of [process.env.PLAYWRIGHT_MODULE, 'playwright', '/home/imcherry/.local/lib/node_modules/playwright'].filter(Boolean)) {
    try { return require(candidate); } catch (_) { /* next */ }
  }
  fail('Playwright module is unavailable');
}
function totp(path) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const seed = privateValue(path).toUpperCase().replace(/=+$/, '');
  let bits = '';
  for (const character of seed) {
    const value = alphabet.indexOf(character);
    if (value < 0) fail('invalid TOTP seed');
    bits += value.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const digest = crypto.createHmac('sha256', Buffer.from(bytes)).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
}
async function api(page, method, path, body, expected) {
  const result = await page.evaluate(async ({methodArg, pathArg, bodyArg}) => {
    const csrf = document.cookie.split('; ').find((entry) => entry.startsWith('csrftoken='))?.split('=')[1] || '';
    const response = await fetch(pathArg, {
      method: methodArg, credentials: 'same-origin',
      headers: {'Content-Type': 'application/json', 'X-CSRFToken': decodeURIComponent(csrf)},
      body: bodyArg === null ? undefined : JSON.stringify(bodyArg),
    });
    return {status: response.status};
  }, {methodArg: method, pathArg: path, bodyArg: body ?? null});
  if (!expected.includes(result.status)) fail(`${method} ${path}: HTTP ${result.status}, expected ${expected.join('/')}`);
  return result;
}
async function login(page, input) {
  await page.goto(AWX_URL, {waitUntil: 'domcontentloaded', timeout: 60000});
  if (new URL(page.url()).hostname === 'sso.imcherry5778.xyz') {
    await page.locator('input[name="username"]').waitFor({state: 'visible', timeout: 30000});
    await page.locator('input[name="username"]').fill(input.username);
    await page.locator('input[name="password"]').fill(privateValue(input['password-file']));
    await page.locator('#kc-login').click();
    await page.locator('input[name="otp"]').waitFor({state: 'visible', timeout: 30000});
    await page.locator('input[name="otp"]').fill(totp(input['totp-file']));
    await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]').first().click();
  }
  await page.waitForURL((url) => url.hostname === 'awx.imcherry5778.xyz', {timeout: 60000});
  const oidc = page.locator('a[href*="/sso/login/oidc/"]').first();
  if (await oidc.isVisible({timeout: 10000}).catch(() => false)) await oidc.click();
  else await page.goto(`${AWX_URL}/sso/login/oidc/`, {waitUntil: 'domcontentloaded', timeout: 60000});
  if (new URL(page.url()).hostname === 'sso.imcherry5778.xyz') {
    await page.locator('input[name="username"]').waitFor({state: 'visible', timeout: 30000});
    await page.locator('input[name="username"]').fill(input.username);
    await page.locator('input[name="password"]').fill(privateValue(input['password-file']));
    await page.locator('#kc-login').click();
    await page.locator('input[name="otp"]').waitFor({state: 'visible', timeout: 30000});
    await page.locator('input[name="otp"]').fill(totp(input['totp-file']));
    await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]').first().click();
  }
  await page.waitForURL((url) => url.hostname === 'awx.imcherry5778.xyz', {timeout: 60000});
  await api(page, 'GET', '/api/v2/me/', null, [200]);
}
async function main() {
  const input = args(process.argv.slice(2));
  const objects = JSON.parse(fs.readFileSync(input['object-file'], 'utf8'));
  const {chromium} = playwright();
  const browser = await chromium.launch({headless: true, args: [
    `--host-resolver-rules=MAP awx.imcherry5778.xyz ${input['connect-ip']},MAP sso.imcherry5778.xyz ${input['connect-ip']}`,
    '--no-proxy-server',
  ]});
  try {
    const context = await browser.newContext({ignoreHTTPSErrors: false});
    const page = await context.newPage();
    await login(page, input);
    await api(page, 'GET', `/api/v2/projects/${objects.project}/`, null, [200]);
    await api(page, 'GET', `/api/v2/job_templates/${objects.template}/`, null, [200]);
    await api(page, 'PATCH', `/api/v2/projects/${objects.project}/`, {scm_branch: 'main'}, [403]);
    await api(page, 'PATCH', `/api/v2/execution_environments/${objects.execution_environment}/`, {description: 'denied'}, [403]);
    await api(page, 'PATCH', `/api/v2/credentials/${objects.credential}/`, {description: 'denied'}, [403]);
    await api(page, 'POST', `/api/v2/job_templates/${objects.template}/launch/`, {scm_branch: 'not-main'}, [403]);
    await context.close();
    console.log('AWX04_RBAC=PASS project_revision=200 template_read=200 project_ee_credential_branch_override=403');
  } finally {
    await browser.close();
  }
}
main().catch((error) => { console.error(`AWX-04 browser verification failed: ${error.message}`); process.exit(1); });
