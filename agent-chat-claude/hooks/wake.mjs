import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, renameSync, rmdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

process.umask(0o077);

const idleText = 'No new agent-chat notices. Call the agent-chat tool chat_identity once so this session keeps waiting, then end the turn with one word.';
const refusedText = 'The chat refused the agent-chat wake token, so this session stopped waiting for notices: the connection was removed or expired, or the agent or its workspace was deleted. Tell the person in one sentence, and say they can type Connect agent-chat to connect again.';
const connectedText = 'agent-chat connected this conversation, and it now waits for notices. Tell the person in one short sentence that it is connected, then end the turn.';
const codeRefusedText = 'The chat refused the agent-chat connection code, so this conversation is not connected. Tell the person, and run the agent-chat connect skill again only if they ask.';
const addressMissingText = 'The agent-chat plugin has no chat address in its .mcp.json, so this conversation is not connected. Tell the person to reinstall the agent-chat plugin.';
const unreachableText = 'agent-chat could not reach the chat to connect this conversation. Tell the person to check the network, and run the agent-chat connect skill again only if they ask.';
const foreignCodeText = 'The agent-chat connection code was not used, because this conversation did not get it from the chat_wake_code tool of agent-chat. Tell the person, and run the agent-chat connect skill again only if they ask.';
const alreadyConnectedText = 'This conversation is already connected to agent-chat, so the new connection code was not used. To connect another agent, the person removes this connection on the Agents page of agent-chat, under Tokens and Plugin connections, and then runs the agent-chat connect skill again.';

const unknownCursor = '999999999999999';
const userAgent = 'agent-chat-wake/1';
const pluginRoot = fileURLToPath(new URL('..', import.meta.url));
const isNumber = (value) => /^\d+$/.test(value ?? '');
const cksumTable = Array.from({ length: 256 }, (_, index) => {
  let value = index << 24;
  for (let bit = 0; bit < 8; bit++) value = value & 0x80000000 ? (value << 1) ^ 0x04c11db7 : value << 1;
  return value >>> 0;
});

const [product = '', action = ''] = process.argv.slice(2);
if (!['codex', 'claude'].includes(product) || !['wait', 'session-start', 'claim'].includes(action)) {
  process.stderr.write('usage: wake.mjs codex|claude wait|session-start|claim\n', () => process.exit(64));
} else {
  await main();
}

async function main() {
  const dir = process.env.AGENT_CHAT_WAKE_DIR
    || (product === 'codex' ? join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'agent-chat')
      : join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'agent-chat'));
  const config = join(dir, 'wake.env');
  const temporary = `${config}.${process.pid}.tmp`;
  const lock = join(dir, 'wake.lock');
  let ownsLock = false;
  let current = null;

  const remove = (path) => { try { rmSync(path, { force: true }); } catch {} };
  const cleanup = () => {
    current?.destroy();
    remove(temporary);
    if (ownsLock) {
      remove(join(lock, 'pid'));
      try { rmdirSync(lock); } catch {}
    }
  };
  process.on('exit', cleanup);
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => process.exit(143));

  const finish = (code, { stdout = null, stderr = null } = {}) => new Promise(() => {
    let left = 1;
    const done = () => { if (--left === 0) process.exit(code); };
    if (stdout !== null) { left++; process.stdout.write(stdout, done); }
    if (stderr !== null) { left++; process.stderr.write(stderr, done); }
    done();
  });

  const readText = (path) => { try { return readFileSync(path, 'utf8'); } catch { return null; } };

  const settings = () => {
    const values = {};
    for (const line of (readText(config) ?? '').split('\n')) {
      const index = line.indexOf('=');
      if (index > 0) values[line.slice(0, index)] = line.slice(index + 1).trim();
    }
    return values;
  };

  const numberSetting = (values, key, fallback) => (isNumber(values[key]) ? Number(values[key]) : fallback);

  const saveSetting = (key, value) => {
    try {
      const lines = (readText(config) ?? '').split('\n').filter((line) => line !== '' && !line.startsWith(`${key}=`));
      if (value) lines.push(`${key}=${value}`);
      writeFileSync(temporary, lines.map((line) => `${line}\n`).join(''));
      renameSync(temporary, config);
      return true;
    } catch {
      remove(temporary);
      return false;
    }
  };

  const alive = (pid) => {
    if (!Number.isSafeInteger(pid) || pid <= 0) return false;
    try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
  };

  const sweep = () => {
    let names;
    try { names = readdirSync(dir); } catch { return; }
    for (const name of names) {
      const owner = /^\.(?:auth|headers|body|status)\.(\d+)$/.exec(name)?.[1] ?? /^wake\.env\.(\d+)\.tmp$/.exec(name)?.[1];
      if (owner && (Number(owner) === process.pid || !alive(Number(owner)))) remove(join(dir, name));
    }
  };
  sweep();

  const values = settings();
  let url = (values.AGENT_CHAT_WAKE_URL ?? '').replace(/\/+$/, '');
  let token = values.AGENT_CHAT_WAKE_TOKEN ?? '';
  let code = values.AGENT_CHAT_WAKE_CODE ?? '';
  const budget = numberSetting(values, 'AGENT_CHAT_WAKE_BUDGET_SECONDS', 1740);
  const waitSeconds = numberSetting(values, 'AGENT_CHAT_WAKE_WAIT_SECONDS', 20);
  const margin = numberSetting(values, 'AGENT_CHAT_WAKE_MARGIN_SECONDS', 15);
  const retryMin = numberSetting(values, 'AGENT_CHAT_WAKE_RETRY_MIN_SECONDS', 2);
  const retryMax = numberSetting(values, 'AGENT_CHAT_WAKE_RETRY_MAX_SECONDS', 60);

  const marks = () => {
    const bytes = Buffer.from(token, 'utf8');
    return { cksum: cksum(bytes), sha: createHash('sha256').update(bytes).digest('hex').slice(0, 12) };
  };
  const ownMark = () => marks()[process.platform === 'win32' ? 'sha' : 'cksum'];

  const marked = (path) => {
    const text = readText(path);
    if (text === null) return { state: 'missing' };
    const parts = text.trim().split(/\s+/);
    if (parts.length === 1 && isNumber(parts[0])) return { state: 'mine', number: parts[0] };
    if (parts.length === 2 && isNumber(parts[1])) {
      const { cksum: posix, sha } = marks();
      return parts[0] === posix || parts[0] === sha ? { state: 'mine', number: parts[1] } : { state: 'foreign' };
    }
    return { state: 'missing' };
  };
  const write = (path, text) => { try { writeFileSync(path, text); return true; } catch { return false; } };
  const saveMarked = (path, number) => write(path, `${ownMark()} ${number}\n`);
  const connectedAsBefore = () => (settings().AGENT_CHAT_WAKE_TOKEN ?? '') === token;

  const send = (method, address, headers, body, timeoutSeconds) => new Promise((resolve) => {
    let settled = false;
    const settle = (answer) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      current = null;
      resolve(answer);
    };
    const failed = () => settle({ status: 0, body: Buffer.alloc(0), cursor: '' });
    const timer = setTimeout(() => { current?.destroy(); failed(); }, timeoutSeconds * 1000);
    let target;
    try { target = new URL(address); } catch { failed(); return; }
    const client = target.protocol === 'https:' ? https : target.protocol === 'http:' ? http : null;
    if (!client) { failed(); return; }
    const outgoing = { 'User-Agent': userAgent, ...headers };
    if (body !== null) Object.assign(outgoing, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    const request = client.request(target, { method, headers: outgoing, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const header = response.headers['x-agent-chat-cursor'];
        const cursor = (Array.isArray(header) ? header.at(-1) : header ?? '').split(',').at(-1).trim();
        settle({ status: response.statusCode ?? 0, body: Buffer.concat(chunks), cursor });
      });
      response.on('error', failed);
      response.on('aborted', failed);
    });
    current = request;
    request.on('error', failed);
    request.end(body ?? undefined);
  });

  const pause = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

  let claimStatus = null;
  const claim = async () => {
    if (!/^[A-Za-z0-9_-]+$/.test(code)) {
      process.stderr.write('No valid AGENT_CHAT_WAKE_CODE in wake.env.\n');
      return false;
    }
    const answer = await send('POST', `${url}/wake/claim`, {}, JSON.stringify({ code }), waitSeconds + margin);
    claimStatus = answer.status;
    const received = answer.body.toString('utf8').replace(/[\r\n]/g, '');
    if (answer.status === 200 && received.startsWith('saw_')) {
      if (!/^[A-Za-z0-9_-]+$/.test(received)) {
        process.stderr.write('The chat answered the claim with an invalid token.\n');
        return false;
      }
      if (!saveSetting('AGENT_CHAT_WAKE_TOKEN', received) || !saveSetting('AGENT_CHAT_WAKE_CODE', '')) return false;
      token = received;
      if (!saveMarked(join(dir, 'cursor'), unknownCursor)) return false;
      remove(join(dir, 'stopped'));
      remove(join(dir, 'pending'));
      return true;
    }
    process.stderr.write(`The chat refused the connection code (HTTP ${String(answer.status).padStart(3, '0')}). Run the connect skill again for a new code.\n`);
    return false;
  };

  const deliverText = (text) => (product === 'codex'
    ? finish(0, { stdout: `${JSON.stringify({ decision: 'block', reason: text })}\n` })
    : finish(2, { stderr: `${text}\n` }));
  const deliverBody = (body) => (product === 'codex' ? finish(0, { stdout: body }) : finish(2, { stderr: body }));

  const exists = (path) => { try { statSync(path); return true; } catch { return false; } };

  const issuedHere = async (transcript, offered) => {
    if (!transcript) return false;
    for (let tries = 0; ; tries++) {
      const text = readText(transcript);
      if (text !== null && text.split('\n').some((line) => line.includes('"server":"agent-chat","tool":"chat_wake_code"')
        && line.includes(`"structuredContent":{"code":"${offered}"`))) return true;
      if (tries >= 4) return false;
      await pause(1);
    }
  };

  const readInput = () => new Promise((resolve) => {
    const chunks = [];
    process.stdin.on('data', (chunk) => chunks.push(chunk));
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    process.stdin.on('error', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });

  const connectFromStop = async () => {
    if (process.stdin.isTTY) return;
    const input = await readInput();
    const offered = [...input.matchAll(/agent-chat wake code: `?(swc_[A-Za-z0-9_-]{43})`?(?:\\n)?"/g)].at(-1)?.[1];
    if (!offered) return;
    if (token && !exists(join(dir, 'stopped'))) await deliverText(alreadyConnectedText);
    let transcript = '';
    try { transcript = `${JSON.parse(input).transcript_path ?? ''}`; } catch {}
    if (!(await issuedHere(transcript, offered))) await deliverText(foreignCodeText);
    let pluginUrl = '';
    try { pluginUrl = `${JSON.parse(readFileSync(join(pluginRoot, '.mcp.json'), 'utf8')).mcpServers['agent-chat'].url ?? ''}`; } catch {}
    pluginUrl = pluginUrl.replace(/\/+$/, '').replace(/\/mcp$/, '');
    if (!pluginUrl) await deliverText(addressMissingText);
    try { mkdirSync(dir, { recursive: true }); } catch { await finish(0); }
    url = pluginUrl;
    code = offered;
    if (!saveSetting('AGENT_CHAT_WAKE_URL', url) || !saveSetting('AGENT_CHAT_WAKE_TOKEN', '') || !saveSetting('AGENT_CHAT_WAKE_CODE', code)) await finish(0);
    if (await claim()) await deliverText(connectedText);
    saveSetting('AGENT_CHAT_WAKE_CODE', '');
    if (claimStatus === 0) await deliverText(unreachableText);
    await deliverText(codeRefusedText);
  };

  if (product === 'codex' && action === 'wait') await connectFromStop();

  try { if (!statSync(dir).isDirectory()) await finish(0); } catch { await finish(0); }
  if (!url) await finish(0);

  if (action === 'claim') {
    if (!(await claim())) await finish(1);
    await finish(0, { stdout: 'Connected: this session now wakes on agent-chat notices.\n' });
  }

  if (exists(join(dir, 'stopped'))) await finish(0);
  if (!token) {
    if (!code) await finish(0);
    if (!(await claim())) await finish(0);
  }
  const authorization = { Authorization: `Bearer ${token}` };

  const savedCursor = marked(join(dir, 'cursor'));
  let cursor = savedCursor.state === 'mine' ? savedCursor.number : savedCursor.state === 'foreign' ? unknownCursor : '0';

  if (action === 'session-start') {
    if (marked(join(dir, 'pending')).state !== 'mine') await finish(0);
    const answer = await send('GET', `${url}/wake?after=${cursor}&wait=0&format=session-start&redelivery=1`, authorization, null, margin);
    await finish(0, answer.status === 200 ? { stdout: answer.body } : {});
  }

  const takeLock = () => { try { mkdirSync(lock); return true; } catch { return false; } };
  if (!takeLock()) {
    const holder = (readText(join(lock, 'pid')) ?? '').trim();
    if (holder) {
      if (alive(Number(holder))) await finish(0);
    } else {
      let changed = 0;
      try { changed = statSync(lock).mtimeMs; } catch {}
      if (changed > Date.now() - 60_000) await finish(0);
    }
    remove(join(lock, 'pid'));
    try { rmdirSync(lock); } catch {}
    if (!takeLock()) await finish(0);
  }
  ownsLock = true;
  write(join(lock, 'pid'), `${process.pid}\n`);

  const pending = marked(join(dir, 'pending'));
  if (pending.state === 'mine') {
    cursor = pending.number;
    saveMarked(join(dir, 'cursor'), cursor);
  }
  remove(join(dir, 'pending'));

  const format = product === 'codex' ? 'stop' : 'text';
  const now = () => Math.floor(Date.now() / 1000);
  const deadline = now() + budget;
  let backoff = retryMin;
  for (;;) {
    let left = deadline - now();
    let waitNow = waitSeconds;
    if (waitNow + margin > left) waitNow = left - margin;
    if (waitNow < 1) break;
    if (!connectedAsBefore()) await finish(0);
    const answer = await send('GET', `${url}/wake?after=${cursor}&wait=${waitNow}&format=${format}`, authorization, null, waitNow + margin);
    if (!connectedAsBefore()) {
      if (answer.status === 200 && isNumber(answer.cursor)) await deliverBody(answer.body);
      await finish(0);
    }
    if (answer.status === 200 && isNumber(answer.cursor)) {
      saveMarked(join(dir, 'pending'), answer.cursor);
      await deliverBody(answer.body);
    }
    if (answer.status === 204) {
      if (cursor === unknownCursor && answer.cursor === unknownCursor) {
        cursor = '0';
        saveMarked(join(dir, 'cursor'), cursor);
      } else if (isNumber(answer.cursor) && answer.cursor !== cursor) {
        cursor = answer.cursor;
        saveMarked(join(dir, 'cursor'), cursor);
      }
      backoff = retryMin;
      continue;
    }
    if (answer.status === 401 || answer.status === 403) {
      write(join(dir, 'stopped'), '');
      await deliverText(refusedText);
    }
    left = deadline - now() - margin;
    if (left < 1) break;
    if (backoff > left) backoff = left;
    await pause(backoff);
    backoff = Math.min(backoff * 2, retryMax);
  }
  await deliverText(idleText);
}

function cksum(bytes) {
  let crc = 0;
  const step = (byte) => { crc = ((crc << 8) ^ cksumTable[((crc >>> 24) ^ byte) & 0xff]) >>> 0; };
  for (const byte of bytes) step(byte);
  for (let length = bytes.length; length > 0; length = Math.floor(length / 256)) step(length & 0xff);
  return String(~crc >>> 0);
}
