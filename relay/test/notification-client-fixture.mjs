// Owned-loopback browser transport fixture only. No ledger or authorization
// claims: real signed Rust/workerd coverage lives in the native host test.
import http from 'node:http';
import { WebSocketServer } from 'ws';

let frames = 0;
const server = http.createServer((request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('content-type', 'application/json');
  response.end(JSON.stringify({frames}));
});
const sockets = new WebSocketServer({noServer: true,
  handleProtocols(protocols, request) {
    return request.url.includes('/1111') ? 'wrong' : protocols.values().next().value;
  },
});
server.on('upgrade', (request, socket, head) => {
  socket.on('error', () => {});
  const upgrade = () => {
    if (socket.destroyed) return;
    sockets.handleUpgrade(request, socket, head, ws => {
    ws.on('error', () => {});
    ws.on('message', () => { frames++; });
    const group = request.url.split('/')[2];
    setTimeout(() => {
      if (ws.readyState !== 1) return;
      ws.send(group.startsWith('2') ? Buffer.from([1, 2]) :
        group.startsWith('3') ? '{"tail":1,"amount":99}' : '{"tail":7}');
    }, 25);
    });
  };
  if (request.url.includes('/4444')) setTimeout(upgrade, 500);
  else upgrade();
});
server.listen(Number(process.argv[2] ?? 8799), '127.0.0.1', () => {
  console.log('browser fixture ready');
  console.log(`PORT:${server.address().port}`);
});
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    for (const ws of sockets.clients) ws.terminate();
    sockets.close();
    server.close();
  });
}
