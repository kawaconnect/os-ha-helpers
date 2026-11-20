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

namespace OPNsense\HaHelpers\FieldTypes;

use OPNsense\Base\FieldTypes\BaseListField;
use OPNsense\Core\Config;

/**
 * Select a CARP virtual IP by its VHID. The stored value is the VHID itself,
 * which is what the helper scripts match against "ifconfig" output; the list
 * shows the address, description and interface so the right one is easy to pick.
 */
class CarpVhidField extends BaseListField
{
    protected function actionPostLoadingEvent()
    {
        if ($this->hasStaticOptions()) {
            $this->internalOptionList = $this->getStaticOptions();
            return;
        }

        $data = [];
        $configObj = Config::getInstance()->object();
        if (!empty($configObj->virtualip) && !empty($configObj->virtualip->vip)) {
            foreach ($configObj->virtualip->vip as $vip) {
                if ((string)$vip->mode != 'carp' || empty((string)$vip->vhid)) {
                    continue;
                }
                $intf = (string)$vip->interface;
                if (!empty((string)$configObj->interfaces->$intf->descr)) {
                    $intf = (string)$configObj->interfaces->$intf->descr;
                } else {
                    $intf = strtoupper($intf);
                }
                $vhid = (string)$vip->vhid;
                $descr = (string)$vip->descr;
                $caption = sprintf(gettext('vhid %s: %s on %s'), $vhid, (string)$vip->subnet, $intf);
                if ($descr !== '') {
                    $caption .= ' (' . $descr . ')';
                }
                /* one VHID can carry several addresses (IP aliases): list it once */
                if (!isset($data[$vhid])) {
                    $data[$vhid] = $caption;
                }
            }
            uksort($data, 'strnatcmp');
        }
        $this->internalOptionList = $this->setStaticOptions($data);
    }

    /**
     * Keep a stored VHID whose CARP address is gone visible and selected.
     * Without it the form would preselect another address and the next save
     * would silently move the helpers to it.
     */
    public function getNodeData()
    {
        $result = parent::getNodeData();
        $value = (string)$this->internalValue;
        if ($value !== '' && !isset($this->internalOptionList[$value])) {
            $result[$value] = [
                'value' => sprintf(gettext('vhid %s: no CARP address'), $value),
                'selected' => 1,
            ];
        }
        return $result;
    }
}
