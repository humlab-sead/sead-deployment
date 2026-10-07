/*
* Who may use the agent. Only signed-in users whose roles give them the sead_agent
* permission - decided by an admin in the web client's admin panel.
*
* The login and the roles both live in json_api_server, so we ask it: the browser's
* session cookie is passed on to its /auth/check/sead_agent, which answers 200 for a
* user with the permission, 401 for no session and 403 for a user without it. This
* holds however a request reaches us - through the router or straight to our port.
*
* Without SEAD_AGENT_AUTH_URL nobody is let in.
*/

const AUTH_URL = (process.env.SEAD_AGENT_AUTH_URL || "").replace(/\/+$/, "");
const PERMISSION = "sead_agent";
//json_api_server's session cookie (AuthenticationHandler.class.js). Only this one is passed on.
const SESSION_COOKIE_NAME = "__Host-sead.sid";
const AUTH_TIMEOUT_MS = parseInt(process.env.SEAD_AGENT_AUTH_TIMEOUT_MS) || 5000;

if(!AUTH_URL) {
    console.warn("SEAD_AGENT_AUTH_URL is not set. Nobody can use the SEAD agent until it points at json_api_server.");
}

/*
* Function: sessionCookieOf
* The session cookie in a Cookie header, as "name=value", or null.
*/
export function sessionCookieOf(cookieHeader) {
    if(typeof cookieHeader != "string") {
        return null;
    }
    for(const part of cookieHeader.split(";")) {
        const separator = part.indexOf("=");
        if(separator > 0 && part.substring(0, separator).trim() == SESSION_COOKIE_NAME) {
            return SESSION_COOKIE_NAME+"="+part.substring(separator + 1).trim();
        }
    }
    return null;
}

/*
* Function: checkAccess
* Whether the request's user may use the agent: { allowed: true, userId } or
* { allowed: false, status, error } with the status and message to answer with.
*/
export async function checkAccess(req, { authUrl = AUTH_URL, fetchImpl = fetch } = {}) {
    if(!authUrl) {
        return { allowed: false, status: 503, error: "The SEAD agent cannot check who you are on this server." };
    }
    const cookie = sessionCookieOf(req.headers.cookie);
    if(!cookie) {
        return { allowed: false, status: 401, error: "Please sign in to use the SEAD agent." };
    }

    let response;
    try {
        response = await fetchImpl(authUrl+"/auth/check/"+PERMISSION, {
            headers: { cookie: cookie },
            signal: AbortSignal.timeout(AUTH_TIMEOUT_MS)
        });
    }
    catch(error) {
        console.error("SEAD agent could not reach json_api_server to check access:", error.message);
        return { allowed: false, status: 503, error: "Your access to the SEAD agent could not be checked. Please try again later." };
    }

    if(response.status == 200) {
        const body = await response.json().catch(() => ({}));
        if(body.allowed === true && typeof body.user_id == "string") {
            return { allowed: true, userId: body.user_id };
        }
    }
    if(response.status == 401) {
        return { allowed: false, status: 401, error: "Please sign in to use the SEAD agent." };
    }
    if(response.status == 403) {
        return { allowed: false, status: 403, error: "Your account does not have access to the SEAD agent." };
    }
    console.error("SEAD agent got an unexpected answer from json_api_server's access check: "+response.status);
    return { allowed: false, status: 503, error: "Your access to the SEAD agent could not be checked. Please try again later." };
}
