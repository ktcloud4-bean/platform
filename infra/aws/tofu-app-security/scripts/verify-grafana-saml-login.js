#!/usr/bin/env node
/* AWS-SEC-02 Managed Grafana -> 온프레미스 Keycloak SAML browser session을 한 번 판정한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');

function fail(message) { throw new Error(message); }
function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]; const value = argv[index + 1];
    if (!key?.startsWith('--') || value === undefined) fail('invalid arguments');
    result[key.slice(2)] = value;
  }
  for (const key of ['workspace-endpoint', 'connect-ip', 'username', 'password-file', 'totp-file']) if (!result[key]) fail(`missing --${key}`);
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  if (!/^g-[a-z0-9]+\.grafana-workspace\.ap-northeast-2\.amazonaws\.com$/.test(result['workspace-endpoint'])) fail('workspace endpoint must be an ap-northeast-2 Amazon Managed Grafana endpoint');
  return result;
}
function loadPlaywright() {
  for (const candidate of [process.env.PLAYWRIGHT_MODULE, 'playwright', '/home/imcherry/.local/lib/node_modules/playwright'].filter(Boolean)) {
    try { return require(candidate); } catch (_) { /* 다음 후보 */ }
  }
  fail('Playwright module is unavailable');
}
function readPrivate(path) { const value = fs.readFileSync(path, 'utf8').trim(); if (!value) fail('private input is empty'); return value; }
async function currentTotp(seedFile) {
  const remaining = 30 - (Math.floor(Date.now() / 1000) % 30);
  if (remaining < 5) await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1000));
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const character of readPrivate(seedFile).toUpperCase().replace(/=+$/, '')) {
    const position = alphabet.indexOf(character); if (position < 0) fail('invalid TOTP seed'); bits += position.toString(2).padStart(5, '0');
  }
  const bytes = []; for (let offset = 0; offset + 8 <= bits.length; offset += 8) bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 1000 / 30)));
  const digest = crypto.createHmac('sha256', Buffer.from(bytes)).update(counter).digest(); const offset = digest[digest.length - 1] & 0x0f;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
}
async function keycloakLogin(page, args) {
  await page.locator('input[name="username"]').waitFor({state: 'visible', timeout: 30000});
  await page.locator('input[name="username"]').fill(args.username);
  await page.locator('input[name="password"]').fill(readPrivate(args['password-file']));
  await page.locator('#kc-login').click();
  try {
    await page.waitForFunction(() => location.hostname !== 'sso.imcherry5778.xyz' || Boolean(document.querySelector('input[name="otp"]')), null, {timeout: 30000});
  } catch (_) {
    const state = await page.evaluate(() => ({
      inputs: [...document.querySelectorAll('input')].map((input) => input.name || input.id || input.type),
      errors: [...document.querySelectorAll('.alert-error, .pf-v5-c-alert, #input-error, .kc-feedback-text')]
        .map((element) => element.textContent.trim()).filter(Boolean),
    }));
    fail(`Keycloak password step did not proceed: ${JSON.stringify(state)}`);
  }
  if (new URL(page.url()).hostname !== 'sso.imcherry5778.xyz') return;
  await page.locator('input[name="otp"]').fill(await currentTotp(args['totp-file']));
  await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]').first().click();
}
async function main() {
  const args = parseArgs(process.argv.slice(2)); const endpoint = args['workspace-endpoint']; const grafanaUrl = `https://${endpoint}`;
  const {chromium} = loadPlaywright();
  const browser = await chromium.launch({executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true, args: [`--host-resolver-rules=MAP sso.imcherry5778.xyz ${args['connect-ip']}`, '--no-proxy-server']});
  try {
    const context = await browser.newContext(); const page = await context.newPage();
    await page.goto(`${grafanaUrl}/login/saml`, {waitUntil: 'domcontentloaded', timeout: 60000});
    await page.waitForURL((url) => url.hostname === 'sso.imcherry5778.xyz', {timeout: 30000});
    await keycloakLogin(page, args);
    await page.waitForURL((url) => url.hostname === endpoint, {timeout: 60000});
    const response = await context.request.get(`${grafanaUrl}/api/user`);
    if (response.status() !== 200) fail(`Grafana SAML session API status=${response.status()}`);
    console.log('AWS-SEC-02 Grafana SAML=PASS keycloak=on-prem session_api=200');
    await context.close();
  } finally { await browser.close(); }
}
main().catch((error) => { console.error(`AWS-SEC-02 Grafana SAML failed: ${error.message}`); process.exitCode = 1; });
