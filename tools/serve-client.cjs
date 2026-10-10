const net = require('net');
const seats = Number(process.argv[2] || 4);
const turns = Number(process.argv[3] || 8);
const train = process.argv[4] === 'train';
let connected = 0, done = 0;
const bufs = Array.from({length: seats}, () => '');
for (let i = 0; i < seats; i++) {
  const s = net.connect(Number(process.argv[5] || 7777), '127.0.0.1', () => { connected++; if (connected === seats) console.log('all attached'); });
  s.on('data', d => {
    bufs[i] += d.toString();
    let nl;
    while ((nl = bufs[i].indexOf('\n')) >= 0) {
      const line = bufs[i].slice(0, nl); bufs[i] = bufs[i].slice(nl + 1);
      if (!line) continue;
      let rec; try { rec = JSON.parse(line); } catch (e) { console.log('seat', i, 'BAD LINE', line.slice(0, 80)); continue; }
      if (rec.type === 'results') { done++; continue; }
      if (rec.turn === undefined) continue;
      if (rec.turn >= turns) { s.write(JSON.stringify({actions: []}) + '\n'); continue; }
      const actions = (train && rec.turn === 3 && i === 0) ? [{action: 'train_unit', params: {unitType: 'worker'}}] : [];
      s.write(JSON.stringify({actions}) + '\n');
    }
  });
  s.on('error', e => console.log('seat', i, 'err', e.message));
}
setTimeout(() => { console.log('client done, seats complete:', done); process.exit(0); }, 30000);
