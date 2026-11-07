# Funkin Online relay server

Small TCP relay (Node.js, no dependencies) used by the in-game **ONLINE** mode.
It only creates rooms and forwards messages between the two players; the game logic runs on the clients.

## Run

```
node tools/online-server/server.js [port]     # default port 7777
npm test --prefix tools/online-server          # run the server tests
```

One of the players (or a VPS) runs it. Both players then type that machine's address in the game
(`host`, `host:port` or `tcp://host:port`).

- Same network: use the host's LAN IP.
- Over the internet: forward TCP port 7777 on the router (or use a VPS / a tunnel such as playit.gg, ngrok tcp, Tailscale).

## How a match works

1. Player A opens ONLINE, enters a name and the server address, and presses CREATE. A 5-character room code appears.
2. Player B enters the same server and the code, and presses JOIN.
3. Both can cycle their character. The host picks song and difficulty and presses START.
4. Both players play the same (player-side) chart. Presses, releases, hits and misses are sent with the song position
   and replayed on the opponent's strumline and character. Scores are compared on the results screen.

Online matches use practice mode (nobody dies), cannot be restarted from the pause menu and never save scores.

## Protocol (v1)

Newline-delimited JSON over TCP, lines up to 4096 bytes.

- Client to server: `create{v,name,char}`, `join{v,code,name,char}`, `leave`, `ping{n}`
- Server to client: `created`, `joined`, `peer_joined`, `peer_left`, `left`, `pong`, `error{code,msg}`
- Relayed between the two players (whitelist): `profile, ready, start, press, release, hit, miss, score, finish, rtt, rtt_ack, chat`

Limits: 400 msgs/s soft (error `rate_limited`), 2000 msgs/s hard (disconnect), 60 s idle timeout.

## Build flag

The client is compiled with `FEATURE_ONLINE` (on for every non-web target). Disable with `-DFEATURE_ONLINE=false`-style
feature flags in `project.hxp` if you don't want it.
