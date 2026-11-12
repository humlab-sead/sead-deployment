"""
Checks on a reply before it goes to the chatbox. They hold whatever the model was talked
into: the model reads text from public web pages - site descriptions, references, whatever
someone typed into a search box - and some of that text can be written to steer it.

The chatbox renders the reply as markdown, so the reply can make the user's browser do
things. An image is fetched the moment it is shown, with no click - an image URL carrying
the conversation in its query string sends it to whoever owns that host. A link is one
click from a page that only looks like ours. So images are never rendered, and a link is
kept only when it goes somewhere we trust; anything else is left as its text.
"""
import logging
import re
from urllib.parse import urlsplit

log = logging.getLogger("sead_agent")

#Hosts a reply may link to, besides the page the chatbox is on. A host also covers its
#subdomains: sead.se covers browser.sead.se.
DEFAULT_LINK_HOSTS = ("sead.se", "doi.org")

#A link target, which markdown lets contain one level of balanced parentheses -
#https://en.wikipedia.org/wiki/Oak_(wood), javascript:alert(1)
DESTINATION = r"<?((?:[^()\s<>]|\([^()\s]*\))*)>?"
TITLE = r"(?:\s+(?:\"[^\"]*\"|'[^']*'))?"
#![alt](url "title") - the alt text is all that survives
IMAGE_PATTERN = re.compile(r"!\[([^\]]*)\]\(\s*"+DESTINATION+TITLE+r"\s*\)")
#[text](url "title")
LINK_PATTERN = re.compile(r"(?<!!)\[([^\]]*)\]\(\s*"+DESTINATION+TITLE+r"\s*\)")
#<https://example.org/>, <mailto:someone@example.org>
AUTOLINK_PATTERN = re.compile(r"<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*)>")
#[ref]: url "title" - a reference definition, which [text][ref] and ![alt][ref] point at
DEFINITION_PATTERN = re.compile(r"^[ \t]{0,3}\[([^\]]+)\]:[ \t]*<?(\S+?)>?(?:[ \t]+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?[ \t]*$", re.MULTILINE)


def host_allowed(host, allowed_hosts):
    host = (host or "").lower().rstrip(".")
    return any(host == allowed or host.endswith("."+allowed) for allowed in allowed_hosts)


def link_allowed(url, allowed_hosts):
    """
    Whether a link may stay clickable. Fragments are the chatbox's own shortcuts
    (#sead-action/...), which the client checks against its command list; a path with no
    host stays on the page's own site.
    """
    url = url.strip()
    if url.startswith("#"):
        return True
    parts = urlsplit(url)
    if not parts.scheme and not parts.netloc:
        #A relative link - but not a protocol-relative one, which has a netloc
        return not url.startswith("//")
    return parts.scheme in ("http", "https") and host_allowed(parts.hostname, allowed_hosts)


def guard_reply(text, allowed_hosts):
    """Returns the reply with images and untrusted links taken out, and what was taken out."""
    removed = []

    def drop_image(match):
        removed.append("image "+match.group(2))
        return match.group(1)

    def check_link(match):
        label, url = match.group(1), match.group(2)
        if link_allowed(url, allowed_hosts):
            return match.group(0)
        removed.append("link "+url)
        return label

    def check_autolink(match):
        url = match.group(1)
        if link_allowed(url, allowed_hosts):
            return match.group(0)
        removed.append("link "+url)
        #Without the angle brackets it is plain text: micromark only links bare URLs with
        #the GFM extension, which the chatbox doesn't use
        return url

    def check_definition(match):
        url = match.group(2)
        if link_allowed(url, allowed_hosts):
            return match.group(0)
        removed.append("link "+url)
        #Without its definition, [text][ref] renders as the plain text it is
        return ""

    text = IMAGE_PATTERN.sub(drop_image, text)
    text = LINK_PATTERN.sub(check_link, text)
    text = AUTOLINK_PATTERN.sub(check_autolink, text)
    text = DEFINITION_PATTERN.sub(check_definition, text)
    #A reference-style image whose definition survived would still be fetched
    text = re.sub(r"!\[([^\]]*)\]\[[^\]]*\]", lambda match: (removed.append("image reference"), match.group(1))[1], text)
    return text, removed
