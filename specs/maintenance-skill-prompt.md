# Maintenance Skill

> Historical design brief for the `maintenance` skill, kept for context on why
> the skill is shaped the way it is. See `skills/maintenance/SKILL.md` and the
> README for how it actually works today.

A skill aimed at performing system-wide maintenance tasks. The most obvious task
to start with is weekly Dependabot sweeps run across a set of development
projects. However, it could include just about anything.

## Maintenance Definitions

Each project that performs maintenance of this sort will be required to define a
skill named `maintenance-<tag>` where the tag is the name of the maintenance to
run. So for a weekly Dependabot sweep, a project could define a
skill named `maintenance-weekly` that performs these and also any other weekly
maintenance requires. It could also define a `maintenance-dependabot` that
`dependabot-weekly` refers to internally to allow just a dependabot focuses
maintenance run that skipped other weekly maintenance tasks. The tags can be
sliced however the operator needs.

## Discovery

The skill will need a script that can look through the operator's project folders to find
all the `maintenance-<tag>` skills that match the argument send to the call.

For example:

```
/zed:maintenance weekly
```

Would use the discovery script to find all the skills in all the operator's projects named
`maintenance-weekly`. 

## Configuration

Typically the projects to perform this task on will be
located in folders or subfolders of `~/projects`, but this is a published plugin
and someone else might not use that folder. Projects may also be located in
a different or additional folders in the future. There needs to be a way to
configure the plugin so that it knows which folders to look into while
performing discovery.

Also, there should be a blocklist for projects that should be ignored because
sometimes a project is no longer worked on, but the working copy is still kept
copy around.

## Execution

All work can be performed in a single Claude Code session with subagents. This
should be performed in an optimal way that avoids toil and token waste. If
possible, running as a batch operation would generally be ideal. If batch
handling is available in Claude Code, it would be good
a `--now` option for the skill that allows skipping of batch handling, but would
still do things in a methodical, serial manner. In either case, we can add a
`--fast` option that runs multiple subagents at a time to perform the
maintenance in parallel (and quickly consuming tokens in the process).

## Observation

Direct observation of work being performed will be in the usual Claude Code
session.

However, for this task there should be a new observation layer: a small web
application that runs locally to
monitor the work. Let's use whichever ultralight local database we can for this.
This lives with the local configuration somewhere for the user. It should be
application to allow browsing of current maintenance run as well as seeing that
status of previous runs at a glance. The current run should include live updates
as actions are performed. This application should show what stage of the process
the skill is in, what projects have been discovered, which jobs are pending,
running, and complete with a red/green status for each completion. And show a
rendered summary of what happened. Use /frontend-design to ensure that this
application is intuitive and useful at a glance and in detail.

Provide the skill whatever scripts are required to update the observability
database, which will then be read by the local observability application, if
running.

The system is expected to have only a single user, but as the `--fast` option might
perform multiple parallel writes, the database needs to be structured in a way
that will prevent data corruption for multiple subagents, so whatever locking on
concurrency mechanisms are required should be employed carefully.

The platform this application runs on does not matter, but it should be easy to
install and run on any developers laptop without a huge number of dependencies.
The goal is a lightweight app with minimal build system running locally in a 
browser window.

## Process

This means that something like the following process is needed to perform this
work:

1. Read configuration
2. Start the monitoring application in the background and open a browser window
   (unless the `--headless` option is specified)
3. Discover projects with the skill
4. Execute the skill for each project in a subagent
    * Run in batch mode, if possible, unless `--now` has been specified.
    * Run one subagent at a time unless `--fast` has been specified.

The user should be able to start or shutdown the observation application at any
time. The script that starts the observation application should make at least a
token effort to avoid running multiple instances and run on a local port that is
unlikely to collide with any other applications the developer might be running
as part of their other development work.


