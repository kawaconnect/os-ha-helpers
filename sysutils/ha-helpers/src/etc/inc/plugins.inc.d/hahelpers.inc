<?php

/*
 * Copyright (C) 2026 KawaConnect LLC
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

function hahelpers_active()
{
    return (new \OPNsense\HaHelpers\HaHelpers())->isActive();
}

function hahelpers_services()
{
    $services = [];

    if (hahelpers_active()) {
        $services[] = [
            'description' => gettext('CARP failover helpers'),
            'configd' => [
                /* render the settings first: an HA sync restarts this on the backup */
                'restart' => ['template reload OPNsense/HaHelpers', 'hahelpers restart'],
                'start' => ['template reload OPNsense/HaHelpers', 'hahelpers start'],
                'stop' => ['hahelpers stop'],
            ],
            'nocheck' => true,
            'name' => 'hahelpers',
        ];
    }

    return $services;
}

function hahelpers_cron()
{
    $jobs = [];

    if (hahelpers_active()) {
        /* OPNsense starts services on reconfigure whatever the CARP role is */
        $jobs[]['autocron'] = ['/usr/local/opnsense/scripts/OPNsense/HaHelpers/master_services.sh', '*/2'];
        /* the backup hands Tailscale subnet routes back to the master (no-op without tailscale nodes) */
        $jobs[]['autocron'] = ['/usr/local/opnsense/scripts/OPNsense/HaHelpers/tailscale_primary.sh', '*/2'];
    }

    return $jobs;
}

function hahelpers_xmlrpc_sync()
{
    $result = [];

    /* only the general settings: the "local" part holds per-node device names */
    $result[] = [
        'description' => gettext('CARP failover helpers'),
        'help' => gettext(
            'Synchronize the CARP failover helper settings (not the per-node interface list) to the other HA host.'
        ),
        'section' => 'OPNsense.HaHelpers.general',
        'id' => 'hahelpers',
        'services' => ['hahelpers'],
    ];

    return $result;
}
