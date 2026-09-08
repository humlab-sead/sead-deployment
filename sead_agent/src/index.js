import express from 'express';
import cors from 'cors';
import SeadAgent from './SeadAgent.class.js';

const PORT = parseInt(process.env.SEAD_AGENT_PORT) || 8585;

const app = express();
//The browser reaches us through the nginx router, which is what sets X-Forwarded-For
app.set('trust proxy', true);
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
