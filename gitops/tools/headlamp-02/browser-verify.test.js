#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const {
  fixedIpv4Lookup,
  headlampCookieScopeUrl,
  headlampToken,
  reserveTotpWindow,
} = require('./browser-verify');

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

async function main() {
  const now = Math.floor(Date.now() / 1000);
  const token = [
    encode({ alg: 'none', typ: 'JWT' }),
    encode({
      iss: 'https://sso.imcherry5778.xyz/realms/platform',
      aud: 'headlamp',
      preferred_username: 'headlamp-daily',
      groups: ['/headlamp-users'],
      iat: now,
      exp: now + 600,
    }),
    'test-signature',
  ].join('.');
  let requestedUrl = '';
  const context = {
    cookies: async (url) => {
      requestedUrl = url;
      return [{ name: 'headlamp-auth-main.0', value: token, path: '/clusters/main' }];
    },
  };

  assert.equal(headlampCookieScopeUrl(), 'https://headlamp.imcherry5778.xyz/clusters/main');
  await headlampToken(context, { username: 'headlamp-daily', group: '/headlamp-users' });
  assert.equal(requestedUrl, headlampCookieScopeUrl());
  console.log('HEADLAMP_COOKIE_SCOPE_TEST=ok,path:/clusters/main');

  let virtualNow = 3010;
  const waits = [];
  const nowSeconds = () => virtualNow;
  const sleep = async (milliseconds) => {
    waits.push(milliseconds);
    virtualNow += milliseconds / 1000;
  };
  const firstWindow = await reserveTotpWindow('test-seed-a', nowSeconds, sleep);
  const secondWindow = await reserveTotpWindow('test-seed-a', nowSeconds, sleep);
  const otherSeedWindow = await reserveTotpWindow('test-seed-b', nowSeconds, sleep);
  assert.equal(firstWindow, 100);
  assert.equal(secondWindow, 101);
  assert.equal(otherSeedWindow, 101);
  assert.deepEqual(waits, [21000]);
  console.log('HEADLAMP_TOTP_WINDOW_TEST=ok,reuse:denied,seed-scope:isolated');

  const lookup = fixedIpv4Lookup('10.10.20.10');
  await new Promise((resolve, reject) => {
    lookup('sso.imcherry5778.xyz', { all: true }, (error, addresses) => {
      try {
        assert.ifError(error);
        assert.deepEqual(addresses, [{ address: '10.10.20.10', family: 4 }]);
        resolve();
      } catch (assertionError) {
        reject(assertionError);
      }
    });
  });
  await new Promise((resolve, reject) => {
    lookup('sso.imcherry5778.xyz', {}, (error, address, family) => {
      try {
        assert.ifError(error);
        assert.equal(address, '10.10.20.10');
        assert.equal(family, 4);
        resolve();
      } catch (assertionError) {
        reject(assertionError);
      }
    });
  });
  console.log('HEADLAMP_IPV4_LOOKUP_TEST=ok,node-all:true-and-false');
}

main().catch((error) => {
  console.error(`browser-verify test failed: ${error.message}`);
  process.exitCode = 1;
});
