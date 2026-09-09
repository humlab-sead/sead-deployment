import express from 'express';
import cors from 'cors';
import SeadAgent from './SeadAgent.class.js';

const PORT = parseInt(process.env.SEAD_AGENT_PORT) || 8585;

const app = express();
//The browser reaches us through the nginx router, which appends to X-Forwarded-For rather
//than replacing it. Trusting the header outright would mean trusting the part of it the
//client wrote, so express is told how many proxies of ours are actually in front - the
//same count SeadAgent counts its client addresses back from.
const TRUSTED_PROXY_COUNT = Number.isInteger(parseInt(process.env.SEAD_AGENT_TRUSTED_PROXY_COUNT))
    ? parseInt(process.env.SEAD_AGENT_TRUSTED_PROXY_COUNT) : 1;
app.set('trust proxy', TRUSTED_PROXY_COUNT);
app.use(cors());
//A chat message is the only thing we ever accept, so the body stays small
app.use(express.json({ limit: '64kb' }));

new SeadAgent(app);

const server = app.listen(PORT, '0.0.0.0', () => {
    console.log("SEAD agent listening on port "+PORT);
});

//Compose stops us with SIGTERM - finish the turns already in flight rather than
//cutting their connections, but don't wait forever for a slow model
const shutdown = (signal) => {
    console.log("SEAD agent received "+signal+", shutting down");
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 15000).unref();
};
process.on('SIGTERM', () => shutdown("SIGTERM"));
process.on('SIGINT', () => shutdown("SIGINT"));
