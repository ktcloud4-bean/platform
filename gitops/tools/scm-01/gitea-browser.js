#!/usr/bin/env node
/* Pomerium groups 판정과 Gitea Keycloak OIDC browser session을 함께 검증한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');

const GITEA_URL = 'https://git.imcherry5778.xyz';
const APPROVED_HOSTS = [
  'git.imcherry5778.xyz',
  'k3s-01.imcherry5778.xyz',
  'sso.imcherry5778.xyz',
];

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
  for (const key of ['connect-ip', 'username', 'password-file', 'totp-file', 'expect']) {
    if (!result[key]) fail(`missing --${key}`);
  }
  if (!net.isIPv4(result['connect-ip'])) fail('connect-ip must be IPv4');
  if (!['allow', 'deny'].includes(result.expect)) fail('expect must be allow or deny');
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

function readPrivate(path) {
  const value = fs.readFileSync(path, 'utf8').trim();
  if (!value) fail('private input is empty');
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
  const value = (digest.readUInt32BE(offset) & 0x7fffffff) % 1000000;
  return value.toString().padStart(6, '0');
}

async function loginPomerium(page, args) {
  await page.goto(GITEA_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForURL('https://sso.imcherry5778.xyz/**', { timeout: 30000 });
  await page.locator('input[name="username"]').fill(args.username);
  await page.locator('input[name="password"]').fill(readPrivate(args['password-file']));
  await page.locator('#kc-login').click();
  await page.locator('input[name="otp"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="otp"]').fill(await currentTotp(args['totp-file']));
  await page.locator(
    'form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]',
  ).first().click();
  await page.waitForURL(`${GITEA_URL}/**`, { timeout: 30000 });
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
    await loginPomerium(page, args);

    if (args.expect === 'deny') {
      const denied = await context.request.get(GITEA_URL, { maxRedirects: 0 });
      if (denied.status() !== 403) fail(`unauthorized Pomerium route status=${denied.status()}`);
      console.log(`gitea-browser: username=${args.username}, pomerium=403, gitea-session=false`);
      await context.close();
      return;
    }

    await page.goto(`${GITEA_URL}/user/login`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    const oauthLink = page.locator('a[href*="/user/oauth2/keycloak"]').first();
    await oauthLink.waitFor({ state: 'visible', timeout: 30000 });
    await oauthLink.click();
    await page.waitForURL(`${GITEA_URL}/**`, { timeout: 30000 });
    await page.waitForLoadState('domcontentloaded');

    await page.locator(`a[href="/${args.username}"]`).first().waitFor({
      state: 'attached',
      timeout: 30000,
    });
    await page.locator('a[href="/user/logout"]').first().waitFor({
      state: 'attached',
      timeout: 30000,
    });
    if (!(await page.title()).includes('Dashboard')) fail('Gitea authenticated dashboard title missing');
    console.log(`gitea-browser: username=${args.username}, pomerium=allow, gitea-oidc=${args.username}`);
    await context.close();
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`gitea-browser failed: ${error.message}`);
  process.exitCode = 1;
});
