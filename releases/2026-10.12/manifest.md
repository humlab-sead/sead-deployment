# SEAD 2026-10.12

An instance comes back by itself after the server reboots: every service now has the
restart policy `always` in place of `unless-stopped`.

## Components

| Component | Version |
| --- | --- |
| Browser client | v1.4.0 |
| JSON API server | v1.64.0 |
| Query API | v1.5.0-multi-polygon.2 |
| Database schema | @2026.10 |

The release builds on 2026-10.11, with the same pins. Only `compose.yml` and
`compose.override.yml` change.

## Restart after a reboot

Rootless podman has no daemon to start containers again when the server boots. That is
done by the user's `podman-restart.service`, which runs
`podman start --all --filter restart-policy=always`: it starts only the containers whose
policy is `always`. With `unless-stopped`, super.sead.se and staging.sead.se stayed down
after humlabsead was rebooted on 2026-11-09, while browser.sead.se, whose legacy stack
already used `always`, came back.

The policy alone is not enough. The instance's user also needs lingering on and the
service enabled, once, in its own session:

```bash
sudo machinectl shell <instance user>@
loginctl show-user "$USER" -p Linger      # Linger=yes
systemctl --user enable podman-restart.service
```

Both are done for browser.sead.se, super.sead.se and staging.sead.se.

## Validation

`podman compose -f compose.yml config -q`.

## Deployment

Targets: super.sead.se (from 2026-10.11) and staging.sead.se (from 2026-10.10). No
`.env-example` changes since 2026-10.10, and the schema tag is unchanged, so neither
needs `generate-env --update` and neither database is rebuilt. Staging also gets the
changes of 2026-10.11.

On the server, as the instance's user, in its checkout:

```bash
./deploy.sh release deploy 2026-10.12
```

The deploy recreates the containers with the new policy. Check it with

```bash
podman ps -aq | xargs podman inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}'
```
