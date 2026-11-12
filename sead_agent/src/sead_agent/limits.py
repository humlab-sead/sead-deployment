"""
What keeps an unauthenticated, public chat endpoint from being used as a free model server.
None of it depends on the model behaving.
"""
import logging
import time

log = logging.getLogger("sead_agent")


def resolve_client_ip(socket_ip, forwarded_for, trusted_proxy_count):
    """
    Which address every per-client limit is counted against, so it has to be one the client
    cannot choose. Traffic reaches us through the nginx router, which *appends* the address it
    saw to X-Forwarded-For rather than replacing the header - so a client that sends an
    X-Forwarded-For of its own keeps it, on the left, and only the entries our own proxies
    added, on the right, are worth anything. Counting from the left would let anyone hand
    themselves a fresh rate limit bucket - and a fresh conversation namespace - with every
    request.
    """
    socket_ip = socket_ip or "unknown"
    #Reached directly rather than through a router of ours: the socket is the client
    if trusted_proxy_count < 1 or not isinstance(forwarded_for, str) or len(forwarded_for) == 0:
        return socket_ip

    hops = [hop.strip() for hop in forwarded_for.split(",") if hop.strip()]
    #The last hop was added by the proxy nearest us, the one before it by the proxy before
    #that; the client is whatever the outermost of our own proxies saw
    index = len(hops) - trusted_proxy_count
    if index < 0:
        #Fewer hops than we have proxies - the header didn't come the way we expect, so fall
        #back to the one address in this request nobody could have written
        log.warning("SEAD agent got an X-Forwarded-For with %d hop(s) behind %d trusted proxies", len(hops), trusted_proxy_count)
        return socket_ip
    return hops[index]


def origin_allowed(origin, allowed_origins):
    """
    Refuses a browser page served from somewhere we don't recognise. It stops the chatbox
    endpoint being wired into a site of someone else's; it is not a wall - a script sends no
    Origin at all and is limited by rate rather than by origin - so leaving the list empty is
    a perfectly sound choice for a public instance.
    """
    if len(allowed_origins) == 0:
        return True
    if not isinstance(origin, str) or len(origin) == 0:
        return True
    return origin.rstrip("/") in allowed_origins


class RateLimiter:
    """
    Two sliding windows per client IP: a short one that catches a burst, and a long one that
    catches the traffic a burst limit alone lets through - someone pacing themselves just under
    it, all day, because our GPU is cheaper than their own.
    """

    def __init__(self, window_ms, max_requests, long_window_ms, long_max_requests, clock=time.time):
        self.window = window_ms / 1000
        self.max_requests = max_requests
        self.long_window = long_window_ms / 1000
        self.long_max_requests = long_max_requests
        self.clock = clock
        #IP -> request timestamps within the longest window
        self.request_log = {}

    def check(self, client_ip):
        """Returns None when the request is allowed, or the window that turned it away."""
        now = self.clock()
        longest_window = max(self.window, self.long_window)

        #Drop stale entries so the map doesn't grow without bound
        for ip in list(self.request_log):
            recent = [stamp for stamp in self.request_log[ip] if stamp > now - longest_window]
            if recent:
                self.request_log[ip] = recent
            else:
                del self.request_log[ip]

        timestamps = self.request_log.get(client_ip, [])
        if len([stamp for stamp in timestamps if stamp > now - self.window]) >= self.max_requests:
            return "burst"
        if len([stamp for stamp in timestamps if stamp > now - self.long_window]) >= self.long_max_requests:
            return "sustained"

        timestamps.append(now)
        self.request_log[client_ip] = timestamps
        return None
