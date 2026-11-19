{#
 # Copyright (C) 2026 KawaConnect LLC
 # All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions are met:
 #
 # 1. Redistributions of source code must retain the above copyright notice,
 #    this list of conditions and the following disclaimer.
 #
 # 2. Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #
 # THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 # AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 # OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 # SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 # INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 # CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 # ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 # POSSIBILITY OF SUCH DAMAGE.
 #}

<script>
    $(document).ready(function () {
        const labels = {
            'host': "{{ lang._('Host') }}",
            'version': "{{ lang._('Plugin version') }}",
            'uptime': "{{ lang._('Uptime (seconds)') }}",
            'vhid': "{{ lang._('Reference VHID') }}",
            'vip': "{{ lang._('Reference address') }}",
            'role': "{{ lang._('Role') }}",
            'masters': "{{ lang._('Addresses in MASTER') }}",
            'backups': "{{ lang._('Addresses in BACKUP') }}",
            'demotion': "{{ lang._('CARP demotion') }}",
            'preempt': "{{ lang._('CARP preempt') }}",
            'pfsync_demotion_factor': "{{ lang._('pfsync demotion factor') }}",
            'maintenance': "{{ lang._('Persistent maintenance mode') }}",
            'pfsync': "{{ lang._('pfsync') }}",
            'states': "{{ lang._('States') }}",
            'peer': "{{ lang._('pfsync peer') }}",
            'default': "{{ lang._('Default route') }}",
            'egress': "{{ lang._('Backup egress routes') }}",
            'gateways': "{{ lang._('Upstream gateways') }}",
            'services': "{{ lang._('Master-only services') }}",
            'keeper': "{{ lang._('CARP VIP DHCP keeper') }}"
        };

        function fill(table, data, names) {
            const $body = $(table).find('tbody').empty();
            const keys = names ? Object.keys(names).filter(k => k in data) : Object.keys(data);
            keys.forEach(function (key) {
                $body.append($('<tr/>')
                    .append($('<td/>').text(names ? names[key] : key))
                    .append($('<td/>').text(data[key] !== '' ? data[key] : '-')));
            });
        }

        function refresh() {
            ajaxGet('/api/hahelpers/status/get', {}, function (data) {
                fill('#status_table', data.status || {}, labels);
                fill('#settings_table', data.settings || {}, null);
            });
        }

        $('#refreshAct').click(function () {
            refresh();
        });
        refresh();
    });
</script>

<ul class="nav nav-tabs" data-tabs="tabs" id="maintabs">
    <li class="active"><a data-toggle="tab" href="#status">{{ lang._('Status') }}</a></li>
    <li><a data-toggle="tab" href="#settings">{{ lang._('Settings in effect') }}</a></li>
</ul>

<div class="tab-content content-box">
    <div id="status" class="tab-pane fade in active">
        <table class="table table-striped table-condensed" id="status_table">
            <tbody></tbody>
        </table>
    </div>
    <div id="settings" class="tab-pane fade in">
        <table class="table table-striped table-condensed" id="settings_table">
            <tbody></tbody>
        </table>
    </div>
</div>

<section class="page-content-main">
    <div class="content-box">
        <div class="col-md-12">
            <br/>
            <button class="btn btn-primary" id="refreshAct" type="button"><b>{{ lang._('Refresh') }}</b></button>
            <br/><br/>
        </div>
    </div>
</section>
