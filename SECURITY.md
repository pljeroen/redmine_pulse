# Security Policy

## Supported versions

This is a young project maintained by one person. Security fixes target the
**latest released version** only (currently the `0.1.x` line). There is no
back-port guarantee for older tags.

## Reporting a vulnerability

**Please do not open a public issue for security problems.** (Public issues and
pull requests are not monitored for this project — see the README.)

Instead, report privately through GitHub's built-in flow:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** (private security advisory).
3. Describe the issue, the affected version, and — if you can — steps to reproduce.

You'll get a best-effort acknowledgement. As a single-maintainer project, response
and fix times are not guaranteed, but genuine, responsibly-disclosed issues will be
taken seriously and credited if you'd like.

## Scope

Pulse reads your Redmine data read-only and is permission-safe by design (it only
ever surfaces what the viewer's own Redmine account may see). The most relevant
classes of report are therefore **permission/visibility leaks** (seeing data you
should not), **injection** in the rendered cockpit or JSON API, and anything that
lets one viewer affect another's cached results.
