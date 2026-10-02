# sead_idp — the dev SAML IdP

A SimpleSAMLphp IdP with local test accounts. On `sead.local` it stands in for SWAMID, so
"SEAD login" can be developed without a federation. It exists only in development: the
service is defined in `compose.override.yml`, which `deploy.sh` disables in prod mode. See
`plans/sead-login-plan.md` §5.

## Accounts

Passwords equal the username. Each covers a case SWAMID IdPs will hit:

| Username | Case |
|---|---|
| `alice` | the full attribute set |
| `bertil` | no `mail` released |
| `cecilia` | many affiliations |
| `asa` | a non-ASCII name (Åsa Öberg-Ström), to exercise the header encoding |
| `david` | no `subject-id`, only `eduPersonPrincipalName`, to exercise the fallback |

Attributes are sent with their `urn:oid` names and NameFormat `uri`, as SWAMID IdPs send
them, and scoped values are scoped to `sead-idp.local`, the scope the IdP's metadata
declares. Accounts are in `config/authsources.php`.

## Setting it up on sead.local

The IdP is its own site, `sead-idp.local`, rather than a subdomain of `sead.local`.
`.local` is not on the public suffix list, so `idp.sead.local` would be same-site with
`sead.local` and dev would not see the cross-site POST back that real IdPs make.

1. Add `sead-idp.local` to the `127.0.0.1` line in `/etc/hosts`.
2. Install `host-nginx/sead-idp.local.conf` as a host nginx site (instructions in the file).
3. Generate the SP's keys, if `deploy.sh` has not already: `router/scripts/generate-sp-keys.sh`.
   The IdP reads the SP's certificates from them, so nothing has to be registered by hand.
4. `./deploy.sh up` (or `podman compose up -d --build sead_idp router`).

The IdP's own test page, `https://sead-idp.local/simplesaml/module.php/admin/test`, logs
in each account through the `sead-personas` source and lists the attributes it would
release. It asks for the admin password, `SAML_DEV_IDP_ADMIN_PASSWORD` in `.env`.
