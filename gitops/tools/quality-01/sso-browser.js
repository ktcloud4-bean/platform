#!/usr/bin/env node
/* 완료 증거 4의 Pomerium groups deny와 SonarQube Keycloak SAML allow를 실제 browser로 대조한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');

const SONAR_URL = 'https://sonar.imcherry5778.xyz';
const APPROVED_HOSTS = [
  'sonar.imcherry5778.xyz',
  'k3s-01.imcherry5778.xyz',
  'sso.imcherry5778.xyz',
];

function fail(message) { throw new Error(message); }

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || value === undefined) fail('invalid arguments');
    result[key.slice(2)] = value;
  }
  for (const key of ['connect-ip', 'username', 'password-file', 'totp-file', 'expect']) {
    if (!result[key]) fail(`missing --${key}`);
  }
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  if (!['allow', 'deny'].includes(result.expect)) fail('expect must be allow or deny');
  return result;
}

function loadPlaywright() {
  for (const candidate of [process.env.PLAYWRIGHT_MODULE, 'playwright', '/home/imcherry/.local/lib/node_modules/playwright'].filter(Boolean)) {
    try { return require(candidate); } catch (_) { /* 다음 후보 */ }
  }
  fail('Playwright module is unavailable');
}

function readPrivate(path) {
  const value = fs.readFileSync(path, 'utf8').trim();
  if (!value) fail(`private input is empty: ${path}`);
  return value;
}

async function currentTotp(seedFile) {
  const remaining = 30 - (Math.floor(Date.now() / 1000) % 30);
  if (remaining < 5) await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1000));
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
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 1000 / 30)));
  const digest = crypto.createHmac('sha256', Buffer.from(bytes)).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
}

async function keycloakLogin(page, args) {
  await page.locator('input[name="username"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="username"]').fill(args.username);
  await page.locator('input[name="password"]').fill(readPrivate(args['password-file']));
  await page.locator('#kc-login').click();
  await page.locator('input[name="otp"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="otp"]').fill(await currentTotp(args['totp-file']));
  await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]')
    .first().click();
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
    await page.goto(SONAR_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForURL('https://sso.imcherry5778.xyz/**', { timeout: 30000 });
    await keycloakLogin(page, args);
    await page.waitForURL(`${SONAR_URL}/**`, { timeout: 30000 });

    if (args.expect === 'deny') {
      const denied = await context.request.get(SONAR_URL, { maxRedirects: 0 });
      if (denied.status() !== 403) fail(`Pomerium deny status=${denied.status()}`);
      console.log(`QUALITY-01 SSO deny: username=${args.username} pomerium_status=403`);
      await context.close();
      return;
    }

    const samlButton = page.locator('a[href*="/sessions/init/saml"], button:has-text("Keycloak"), a:has-text("Keycloak")').first();
    await samlButton.waitFor({ state: 'visible', timeout: 30000 });
    await samlButton.click();
    await page.waitForURL(`${SONAR_URL}/**`, { timeout: 30000 });
    await page.waitForLoadState('domcontentloaded');
    const validation = await context.request.get(`${SONAR_URL}/api/authentication/validate`);
    const body = await validation.json();
    if (validation.status() !== 200 || body.valid !== true) fail('SonarQube SAML session is not valid');
    console.log(`QUALITY-01 SSO allow: username=${args.username} sonarqube_session=true`);
    await context.close();
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`QUALITY-01 sso-browser failed: ${error.message}`);
  process.exitCode = 1;
});
