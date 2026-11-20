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
        /*
         * Offer what this node has as choices in the free-form lists: service names
         * from the service list, device names from the interface list. Other values
         * can still be typed. A failed lookup (no access to those pages) only means
         * no suggestions.
         */
        function addChoices(fieldId, values) {
            const $select = $('select[id="' + fieldId + '"]');
            values.forEach(function (value) {
                if ($select.find('option').filter(function () { return this.value === value; }).length === 0) {
                    $select.append($('<option/>').val(value).text(value));
                }
            });
        }

        function lookup(url, extract) {
            const dfObj = $.Deferred();
            $.ajax({url: url, type: 'GET', dataType: 'json', timeout: 5000})
                .done(function (data) { dfObj.resolve(extract(data)); })
                .fail(function () { dfObj.resolve([]); });
            return dfObj;
        }

        function showWarnings() {
            ajaxGet('/api/hahelpers/status/get', {}, function (data) {
                const status = data.status || {};
                const notes = [];
                if (status.keeper_routing) {
                    notes.push("{{ lang._('An os-carp-vip-dhcp keeper enforces routes of its own on this node (%s). In Services: CARP VIP DHCP set Own default route by CARP role to Off or Observe, or turn off the matching setting here. Two route managers fight over the same routes.') }}".replace('%s', status.keeper_routing));
                }
                if (status.vhid && !status.role) {
                    notes.push("{{ lang._('The selected CARP address is not active on this node, so the helpers do nothing. Check Interfaces: Virtual IPs: Status.') }}");
                }
                const $box = $('#hahelpers_warnings').empty();
                notes.forEach(function (note) { $box.append($('<div class="alert alert-warning" role="alert"/>').text(note)); });
            });
        }

        mapDataToFormUI({'frm_GeneralSettings': '/api/hahelpers/settings/get'}).done(function () {
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
            /* the tokenizer reads the options on each search, so late suggestions need no refresh */
            $.when(
                lookup('/api/core/service/search', function (data) {
                    /* never the services a node needs in either role */
                    const never = ['hahelpers', 'carpvipdhcp', 'configd', 'webgui', 'openssh', 'pf', 'syslog-ng',
                        'dpinger', 'routing', 'unbound', 'cron', 'ntpd', 'tailscale'];
                    return (data.rows || []).filter(function (row) { return !row.locked; })
                        .map(function (row) { return row.name; })
                        .filter(function (name, i, all) {
                            return name && never.indexOf(name) === -1 && all.indexOf(name) === i;
                        })
                        .sort();
                }),
                lookup('/api/diagnostics/interface/get_interface_names', function (data) {
                    return Object.keys(data || {}).sort();
                })
            ).done(function (services, devices) {
                addChoices('hahelpers.general.masterOnlyServices', services);
                addChoices('hahelpers.local.jumboMtuInterfaces', devices);
            });
            updateServiceControlUI('hahelpers');
            showWarnings();
        });

        $('#reconfigureAct').SimpleActionButton({
            onPreAction: function () {
                const dfObj = $.Deferred();
                saveFormToEndpoint('/api/hahelpers/settings/set', 'frm_GeneralSettings', dfObj.resolve, true, dfObj.reject);
                return dfObj;
            },
            onAction: function () {
                updateServiceControlUI('hahelpers');
                showWarnings();
            }
        });
    });
</script>

<div id="hahelpers_warnings"></div>

<div class="content-box">
    {{ partial('layout_partials/base_form', ['fields': generalForm, 'id': 'frm_GeneralSettings']) }}
</div>

{{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/hahelpers/service/reconfigure', 'data_service_widget': 'hahelpers'}) }}
