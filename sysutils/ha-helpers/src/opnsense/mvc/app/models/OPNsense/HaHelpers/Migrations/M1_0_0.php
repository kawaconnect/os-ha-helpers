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

namespace OPNsense\HaHelpers\Migrations;

use OPNsense\Base\BaseModelMigration;

/**
 * First install: import the settings of the shell script kit this plugin
 * replaces (opnsense-ha, /usr/local/etc/kc-ha.conf), so a node keeps behaving
 * as before. The file is read as plain KEY=value lines and never executed.
 * Values that do not validate keep the model default; settings that only the
 * management-side tools used (CHECK_*, DRILL_*) are not part of the plugin.
 *
 * Core finds a migration by this name (M<major>_<minor>_<patch>).
 */
// phpcs:ignore Squiz.Classes.ValidClassName
class M1_0_0 extends BaseModelMigration
{
    private const LEGACY_CONF = '/usr/local/etc/kc-ha.conf';

    /* legacy name => [section, field, kind] */
    private const MAP = [
        'VHID' => ['general', 'vhid', 'int'],
        'BOOT_GRACE' => ['general', 'bootGrace', 'int'],
        'MASTER_ONLY_SERVICES' => ['general', 'masterOnlyServices', 'list'],
        'SERVICE_SETTLE' => ['general', 'serviceSettle', 'int'],
        'BACKUP_EGRESS' => ['general', 'backupEgress', 'bool'],
        'PIN_DEFAULT_ROUTE' => ['general', 'pinDefaultRoute', 'bool'],
        'UNUSABLE_DEFAULT_GWS' => ['general', 'unusableDefaultGws', 'list'],
        'GW_PING_TIMEOUT_MS' => ['general', 'gwPingTimeout', 'int'],
        'PEER_PING_TIMEOUT_MS' => ['general', 'peerPingTimeout', 'int'],
        'UNBOUND_RESTART_ON_MASTER' => ['general', 'unboundRestart', 'bool'],
        'DNS_CHECK_NAME' => ['general', 'dnsCheckName', 'text'],
        'DNS_CHECK_SERVER' => ['general', 'dnsCheckServer', 'text'],
        'DNS_RESTART_TRIES' => ['general', 'dnsRestartTries', 'int'],
        'DNS_SETTLE' => ['general', 'dnsSettle', 'int'],
        'DNS_RETRY_WAIT' => ['general', 'dnsRetryWait', 'int'],
        'PFSYNC_MAXUPD' => ['general', 'pfsyncMaxupd', 'maxupd'],
        'EGRESS_HOOK_DELAY' => ['general', 'egressHookDelay', 'int'],
        'SERVICES_HOOK_DELAY' => ['general', 'servicesHookDelay', 'int'],
        'SERVICES_BOOT_DELAY' => ['general', 'servicesBootDelay', 'int'],
        'LOCK_TIMEOUT' => ['general', 'lockTimeout', 'int'],
        'TAILSCALE_NODES' => ['general', 'tailscaleNodes', 'list'],
        'TAILSCALE_HANDOVER_HOLD' => ['general', 'tailscaleHandoverHold', 'int'],
        'JUMBO_MTU_IFS' => ['local', 'jumboMtuInterfaces', 'list'],
        'JUMBO_MTU' => ['local', 'jumboMtu', 'int'],
    ];

    public function run($model)
    {
        if (!is_readable(self::LEGACY_CONF)) {
            return;
        }
        $values = self::parse(file_get_contents(self::LEGACY_CONF));
        foreach (self::MAP as $key => list($section, $field, $kind)) {
            if (!array_key_exists($key, $values)) {
                continue;
            }
            $node = $model->$section->$field;
            $old = (string)$node;
            $node->setValue(self::convert($values[$key], $kind));
            foreach ($model->performValidation(true) as $message) {
                if ($message->getField() == "{$section}.{$field}") {
                    /* keep the default for a value the model does not accept */
                    $node->setValue($old);
                    syslog(LOG_WARNING, "ha-helpers: ignored {$key} from " . self::LEGACY_CONF . ', not a valid value');
                    break;
                }
            }
        }
        if (!$model->general->vhid->isEmpty()) {
            $model->general->enabled = '1';
        }
    }

    /**
     * KEY=value lines as the shell kit wrote them; quotes are stripped, nothing
     * is expanded. The last assignment of a key wins, as it did in the shell.
     */
    private static function parse($text)
    {
        $result = [];
        foreach (preg_split('/\r?\n|;/', (string)$text) as $line) {
            if (preg_match('/^\s*([A-Z][A-Z0-9_]*)=("([^"]*)"|\'([^\']*)\'|([^\s#]*))/', $line, $m)) {
                $result[$m[1]] = $m[3] !== '' ? $m[3] : (($m[4] ?? '') !== '' ? $m[4] : ($m[5] ?? ''));
            }
        }
        return $result;
    }

    private static function convert($value, $kind)
    {
        $value = trim($value);
        switch ($kind) {
            case 'bool':
                /* the same words the shell kit accepted */
                return in_array($value, ['yes', 'YES', '1', 'on', 'true'], true) ? '1' : '0';
            case 'list':
                return implode(',', preg_split('/[\s,]+/', $value, -1, PREG_SPLIT_NO_EMPTY));
            case 'maxupd':
                return $value === '' ? '0' : $value;
            default:
                return $value;
        }
    }
}
