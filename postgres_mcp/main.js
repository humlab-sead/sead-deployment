import express from "express";
import { randomUUID, timingSafeEqual } from "crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { Pool } from "pg";

/**
 * Environment
 */
const PORT = Number(process.env.PORT || 4000);
const MCP_PATH = process.env.MCP_PATH || "/mcp";
const MCP_BEARER_TOKEN = process.env.MCP_BEARER_TOKEN;

if (!MCP_BEARER_TOKEN) throw new Error("Missing MCP_BEARER_TOKEN");

const PGHOST = process.env.PGHOST || "postgresql";
const PGPORT = Number(process.env.PGPORT || 5432);
const PGDATABASE = process.env.PGDATABASE;
const PGUSER = process.env.PGUSER;
const PGPASSWORD = process.env.PGPASSWORD;
const PGSSL = (process.env.PGSSL || "false").toLowerCase() === "true";

if (!PGDATABASE) throw new Error("Missing PGDATABASE");
if (!PGUSER) throw new Error("Missing PGUSER");
if (!PGPASSWORD) throw new Error("Missing PGPASSWORD");

const pool = new Pool({
  host: PGHOST,
  port: PGPORT,
  database: PGDATABASE,
  user: PGUSER,
  password: PGPASSWORD,
  ssl: PGSSL ? { rejectUnauthorized: false } : false,
  max: Number(process.env.PGPOOL_MAX || 10),
  idleTimeoutMillis: Number(process.env.PG_IDLE_TIMEOUT_MS || 30000),
  connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 10000)
});

async function withClient(fn) {
  const client = await pool.connect();
  try {
    await client.query("SET statement_timeout = 15000");
    await client.query("SET idle_in_transaction_session_timeout = 15000");
    return await fn(client);
  } finally {
    client.release();
  }
}

function normalizeSql(sql) {
  return sql.trim().replace(/;+$/g, "").trim();
}

function isReadOnlySql(sql) {
  const normalized = normalizeSql(sql);
  const lower = normalized.toLowerCase();

  if (!normalized) return false;
  if (normalized.includes(";")) return false; // disallow multiple statements

  const allowedStarts = ["select", "with", "explain"];
  if (!allowedStarts.some(prefix => lower.startsWith(prefix))) {
    return false;
  }

  return true;
}

function getSqlKind(sql) {
  const lower = normalizeSql(sql).toLowerCase();
  if (lower.startsWith("explain")) return "explain";
  if (lower.startsWith("with")) return "with";
  return "select";
}

function parseBearerToken(authHeader) {
  if (typeof authHeader !== "string") return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function isValidBearerToken(token, expectedToken) {
  if (!token || !expectedToken) return false;
  const tokenBuffer = Buffer.from(token, "utf8");
  const expectedBuffer = Buffer.from(expectedToken, "utf8");
  if (tokenBuffer.length !== expectedBuffer.length) return false;
  return timingSafeEqual(tokenBuffer, expectedBuffer);
}

async function runReadOnlyQuery(sql, values = []) {
  return withClient(async client => {
    await client.query("BEGIN");
    try {
      await client.query("SET TRANSACTION READ ONLY");
      const result = await client.query(sql, values);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      try {
        await client.query("ROLLBACK");
      } catch {}
      throw error;
    }
  });
}

function errorMessageForClient(prefix, error) {
  if (process.env.NODE_ENV === "development") {
    return `${prefix}: ${error.message}`;
  }
  return `${prefix}.`;
}

function isInitializeRequest(body) {
  return Boolean(body && !Array.isArray(body) && body.method === "initialize");
}

function getSingleHeaderValue(header) {
  if (Array.isArray(header)) return header[0] ?? null;
  return typeof header === "string" ? header : null;
}

function serverText(value) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }]
  };
}

function serverError(message) {
  return {
    content: [{ type: "text", text: message }],
    isError: true
  };
}

function makeServer() {
  const server = new McpServer(
    {
      name: "postgres-mcp",
      version: "1.0.0"
    },
    {
      capabilities: {
        logging: {}
      }
    }
  );

  server.registerTool(
    "db_ping",
    {
      title: "Database Ping",
      description: "Check database connectivity and return server/database identity.",
      inputSchema: {}
    },
    async (_, ctx) => {
      try {
        const result = await withClient(client =>
          client.query(`
            select
              current_database() as database,
              current_user as user,
              inet_server_addr()::text as server_addr,
              inet_server_port() as server_port,
              version() as postgres_version
          `)
        );

        await ctx?.mcpReq?.log?.("info", "db_ping executed");

        return serverText(result.rows[0]);
      } catch (error) {
        await ctx?.mcpReq?.log?.("error", `db_ping failed: ${error.message}`);
        return serverError(errorMessageForClient("db_ping failed", error));
      }
    }
  );

  server.registerTool(
    "list_tables",
    {
      title: "List Tables",
      description: "List base tables and views in non-system schemas.",
      inputSchema: {
        schema: z.string().optional().describe("Optional schema name filter")
      }
    },
    async ({ schema }, ctx) => {
      try {
        const result = await withClient(client =>
          client.query(
            `
            select
              table_schema,
              table_name,
              table_type
            from information_schema.tables
            where table_schema not in ('pg_catalog', 'information_schema')
              and ($1::text is null or table_schema = $1)
            order by table_schema, table_name
            `,
            [schema ?? null]
          )
        );

        await ctx?.mcpReq?.log?.("info", `list_tables returned ${result.rowCount} rows`);

        return serverText(result.rows);
      } catch (error) {
        await ctx?.mcpReq?.log?.("error", `list_tables failed: ${error.message}`);
        return serverError(errorMessageForClient("list_tables failed", error));
      }
    }
  );

  server.registerTool(
    "describe_table",
    {
      title: "Describe Table",
      description: "Describe columns for a given table.",
      inputSchema: {
        schema: z.string().describe("Schema name"),
        table: z.string().describe("Table name")
      }
    },
    async ({ schema, table }, ctx) => {
      try {
        const result = await withClient(client =>
          client.query(
            `
            select
              column_name,
              data_type,
              is_nullable,
              column_default,
              ordinal_position
            from information_schema.columns
            where table_schema = $1
              and table_name = $2
            order by ordinal_position
            `,
            [schema, table]
          )
        );

        if (result.rowCount === 0) {
          return serverError(`No columns found for ${schema}.${table}`);
        }

        await ctx?.mcpReq?.log?.("info", `describe_table for ${schema}.${table}`);

        return serverText(result.rows);
      } catch (error) {
        await ctx?.mcpReq?.log?.("error", `describe_table failed: ${error.message}`);
        return serverError(errorMessageForClient("describe_table failed", error));
      }
    }
  );

  server.registerTool(
    "query_readonly",
    {
      title: "Run Read-Only SQL",
      description:
        "Execute a single read-only SQL statement (SELECT / WITH / EXPLAIN). Rejects writes and multi-statement SQL.",
      inputSchema: {
        sql: z.string().describe("A single read-only SQL statement"),
        limit: z.number().int().min(1).max(1000).default(200).describe("Max rows to return")
      }
    },
    async ({ sql, limit }, ctx) => {
      try {
        const normalized = normalizeSql(sql);

        if (!isReadOnlySql(normalized)) {
          return serverError(
            "Rejected SQL. Only a single read-only SELECT/WITH/EXPLAIN statement is allowed."
          );
        }

        let result;
        if (getSqlKind(normalized) === "explain") {
          result = await runReadOnlyQuery(normalized);
          result.rows = result.rows.slice(0, limit);
          result.rowCount = result.rows.length;
        } else {
          const limitedSql = `
            select * from (
              ${normalized}
            ) as mcp_query
            limit $1
          `;
          result = await runReadOnlyQuery(limitedSql, [limit]);
        }

        await ctx?.mcpReq?.log?.("info", `query_readonly returned ${result.rowCount} rows`);

        return serverText({
          rowCount: result.rowCount,
          rows: result.rows
        });
      } catch (error) {
        await ctx?.mcpReq?.log?.("error", `query_readonly failed: ${error.message}`);
        return serverError(errorMessageForClient("query_readonly failed", error));
      }
    }
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "1mb" }));
const transports = new Map();

app.use((req, res, next) => {
  if (req.path === "/healthz") return next();
  const token = parseBearerToken(getSingleHeaderValue(req.headers["authorization"]));
  if (!isValidBearerToken(token, MCP_BEARER_TOKEN)) {
    res.setHeader("WWW-Authenticate", "Bearer");
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
});

app.get("/healthz", async (_req, res) => {
  try {
    const result = await withClient(client => client.query("select 1 as ok"));
    res.status(200).json({ ok: result.rows[0].ok === 1 });
  } catch (error) {
    res.status(500).json({ ok: false, error: errorMessageForClient("healthz failed", error) });
  }
});

app.post(MCP_PATH, async (req, res) => {
  const sessionId = getSingleHeaderValue(req.headers["mcp-session-id"]);

  try {
    if (sessionId && transports.has(sessionId)) {
      const state = transports.get(sessionId);
      await state.transport.handleRequest(req, res, req.body);
      return;
    }

    if (!sessionId && isInitializeRequest(req.body)) {
      const sessionServer = makeServer();
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: initializedSessionId => {
          transports.set(initializedSessionId, { transport, server: sessionServer });
        }
      });

      transport.onclose = async () => {
        const currentSessionId = transport.sessionId;
        if (currentSessionId) {
          transports.delete(currentSessionId);
        }
        try {
          await sessionServer.close();
        } catch {}
      };

      await sessionServer.connect(transport);
      await transport.handleRequest(req, res, req.body);
      return;
    }

    // Backward-compatible stateless handling for non-session clients.
    const statelessServer = makeServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined
    });

    await statelessServer.connect(transport);
    await transport.handleRequest(req, res, req.body);

    res.on("close", async () => {
      try {
        await transport.close();
      } catch {}
      try {
        await statelessServer.close();
      } catch {}
    });
  } catch (error) {
    console.error("MCP request failed:", error);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: {
          code: -32603,
          message: "Internal server error"
        },
        id: null
      });
    }
  }
});

app.get(MCP_PATH, async (req, res) => {
  const sessionId = getSingleHeaderValue(req.headers["mcp-session-id"]);
  if (!sessionId || !transports.has(sessionId)) {
    res.status(400).json({
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: "Invalid or missing MCP session ID."
      },
      id: null
    });
    return;
  }

  try {
    const state = transports.get(sessionId);
    await state.transport.handleRequest(req, res);
  } catch (error) {
    console.error("MCP GET request failed:", error);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: {
          code: -32603,
          message: "Internal server error"
        },
        id: null
      });
    }
  }
});

app.delete(MCP_PATH, async (req, res) => {
  const sessionId = getSingleHeaderValue(req.headers["mcp-session-id"]);
  if (!sessionId || !transports.has(sessionId)) {
    res.status(400).json({
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: "Invalid or missing MCP session ID."
      },
      id: null
    });
    return;
  }

  try {
    const state = transports.get(sessionId);
    await state.transport.handleRequest(req, res);
  } catch (error) {
    console.error("MCP DELETE request failed:", error);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: {
          code: -32603,
          message: "Internal server error"
        },
        id: null
      });
    }
  }
});

const server = app.listen(PORT, "0.0.0.0", () => {
  console.log(`postgres-mcp listening on 0.0.0.0:${PORT}${MCP_PATH}`);
  console.log(`postgres target: ${PGHOST}:${PGPORT}/${PGDATABASE}`);
});

async function shutdown(signal) {
  console.log(`Received ${signal}, shutting down...`);
  server.close(async () => {
    try {
      const states = Array.from(transports.values());
      await Promise.all(
        states.map(async state => {
          try {
            await state.transport.close();
          } catch {}
          try {
            await state.server.close();
          } catch {}
        })
      );
      transports.clear();
      await pool.end();
    } finally {
      process.exit(0);
    }
  });
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
