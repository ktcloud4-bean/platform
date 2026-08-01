#!/usr/bin/env node
/* 실제 headless Chrome에서 Pomerium + Keycloak + Dashy 그룹별 타일을 검증한다. */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');

const ACCESS_URL = 'https://access.imcherry5778.xyz';
const PROTECTED_URL = `${ACCESS_URL}/pom01-platform-user-check`;
const PORTAL_TILE_URL = PROTECTED_URL;
const APPROVED_HOSTS = [
  'access.imcherry5778.xyz',
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

function readPrivate(filePath) {
  const value = fs.readFileSync(filePath, 'utf8').trim();
  if (!value) fail('private input is empty');
  return value;
}

async function currentTotp(seedFile) {
  const remaining = 30 - (Math.floor(Date.now() / 1000) % 30);
  if (remaining < 5) await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1000));
  // Node Buffer는 base32를 직접 지원하지 않으므로 엄격한 로컬 decoder를 쓴다.
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

async function loginKeycloak(page, args) {
  await page.locator('input[name="username"]').fill(args.username);
  await page.locator('input[name="password"]').fill(readPrivate(args['password-file']));
  await page.locator('#kc-login').click();
  await page.locator('input[name="otp"]').waitFor({ state: 'visible', timeout: 30000 });
  await page.locator('input[name="otp"]').fill(await currentTotp(args['totp-file']));
  await page.locator('form#kc-otp-login-form button[type="submit"], form#kc-otp-login-form input[type="submit"]')
    .first().click();
  await page.waitForURL(`${PROTECTED_URL}*`, { timeout: 30000 });
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
    await page.goto(PROTECTED_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForURL('https://sso.imcherry5778.xyz/**', { timeout: 30000 });
    await loginKeycloak(page, args);

    const routeResponse = await context.request.get(PROTECTED_URL, { maxRedirects: 0 });
    if (args.expect === 'allow') {
      if (routeResponse.status() !== 200 || (await routeResponse.text()) !== 'POM-01 protected route\n') {
        fail('allowed protected route did not return exact 200 marker');
      }
    } else if (routeResponse.status() !== 403) {
      fail(`denied protected route status=${routeResponse.status()}`);
    }

    await page.goto(`${ACCESS_URL}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForFunction(
      () => document.body && document.body.innerText.includes('Platform Access'),
      undefined,
      { timeout: 45000 },
    );
    const tile = page.locator(`a[href="${PORTAL_TILE_URL}"]`);
    const tileVisible = (await tile.count()) > 0 && await tile.first().isVisible();
    if (args.expect === 'allow' && !tileVisible) fail('allowed Dashy tile is not visible');
    if (args.expect === 'deny' && tileVisible) fail('unauthorized Dashy tile is visible');

    console.log(
      `dashy-browser: username=${args.username}, expect=${args.expect}, protected-route=${routeResponse.status()}, tile-visible=${tileVisible}`,
    );
    await context.close();
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`dashy-browser failed: ${error.message}`);
  process.exitCode = 1;
});
