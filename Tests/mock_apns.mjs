// A local stand-in for Apple's push service, for Tests/test_push_e2e.py: real HTTP/2 over TLS (ALPN h2), the way
// api.push.apple.com speaks it. Every request is appended to a JSON-lines log. Answers follow a rules file that is
// re-read per request, so a test can change them mid-run: {"<device token>": [status, "Reason"]}; anything else
// gets 200 with an apns-id, like a delivered notification.
//
//   node Tests/mock_apns.mjs <tls key> <tls cert> <request log> <rules file>     prints "PORT <n>" once listening
import http2 from 'node:http2';
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , keyFile, certFile, logFile, rulesFile] = process.argv;

function rules() {
  try {
    return JSON.parse(fs.readFileSync(rulesFile, 'utf8'));
  } catch {
    return {};
  }
}

const server = http2.createSecureServer({
  key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile), allowHTTP1: false,
});

server.on('stream', (stream, headers) => {
  const chunks = [];
  stream.on('data', (chunk) => chunks.push(chunk));
  stream.on('end', () => {
    const path = headers[':path'] || '';
    const token = path.split('/').pop();
    const record = {
      at: Date.now() / 1000,
      alpn: stream.session.alpnProtocol,
      method: headers[':method'],
      scheme: headers[':scheme'],
      path,
      headers: Object.fromEntries(Object.entries(headers).filter(([name]) => !name.startsWith(':'))),
      body: Buffer.concat(chunks).toString('utf8'),
    };
    const rule = rules()[token];
    record.answer = rule ? rule[0] : 200;
    fs.appendFileSync(logFile, JSON.stringify(record) + '\n');
    const id = crypto.randomUUID();
    if (rule) {
      stream.respond({ ':status': rule[0], 'apns-id': id, 'content-type': 'application/json' });
      stream.end(JSON.stringify({ reason: rule[1], ...(rule[0] === 410 ? { timestamp: Date.now() } : {}) }));
    } else {
      stream.respond({ ':status': 200, 'apns-id': id });
      stream.end();
    }
  });
});

server.listen(0, '127.0.0.1', () => process.stdout.write('PORT ' + server.address().port + '\n'));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
