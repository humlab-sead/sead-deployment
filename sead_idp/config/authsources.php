<?php

/**
 * The dev IdP's accounts. Fake people, committed on purpose: each one covers a case
 * real SWAMID IdPs will hit (plans/sead-login-plan.md §5.3). Passwords equal the
 * username.
 *
 * Attributes use the same urn:oid names (NameFormat uri) as SWAMID IdPs, so the SP
 * handles them exactly as it will online. Scoped values are scoped to sead-idp.local,
 * the shibmd:Scope this IdP's metadata declares - the SP drops values outside it.
 */

const SUBJECT_ID = 'urn:oasis:names:tc:SAML:attribute:subject-id';
const EPPN = 'urn:oid:1.3.6.1.4.1.5923.1.1.1.6';
const DISPLAY_NAME = 'urn:oid:2.16.840.1.113730.3.1.241';
const GIVEN_NAME = 'urn:oid:2.5.4.42';
const SURNAME = 'urn:oid:2.5.4.4';
const MAIL = 'urn:oid:0.9.2342.19200300.100.1.3';
const SCOPED_AFFILIATION = 'urn:oid:1.3.6.1.4.1.5923.1.1.1.9';
const HOME_ORGANIZATION = 'urn:oid:1.3.6.1.4.1.25178.1.2.9';

$config = [
    'admin' => [
        'core:AdminPassword',
    ],

    'sead-personas' => [
        'exampleauth:UserPass',

        'users' => [
            // The full attribute set
            'alice:alice' => [
                SUBJECT_ID => ['alice@sead-idp.local'],
                EPPN => ['alice@sead-idp.local'],
                DISPLAY_NAME => ['Alice Andersson'],
                GIVEN_NAME => ['Alice'],
                SURNAME => ['Andersson'],
                MAIL => ['alice.andersson@sead-idp.local'],
                SCOPED_AFFILIATION => ['member@sead-idp.local', 'staff@sead-idp.local'],
                HOME_ORGANIZATION => ['sead-idp.local'],
            ],
            // No mail released
            'bertil:bertil' => [
                SUBJECT_ID => ['bertil@sead-idp.local'],
                EPPN => ['bertil@sead-idp.local'],
                DISPLAY_NAME => ['Bertil Berg'],
                GIVEN_NAME => ['Bertil'],
                SURNAME => ['Berg'],
                SCOPED_AFFILIATION => ['member@sead-idp.local', 'faculty@sead-idp.local'],
                HOME_ORGANIZATION => ['sead-idp.local'],
            ],
            // Many affiliations
            'cecilia:cecilia' => [
                SUBJECT_ID => ['cecilia@sead-idp.local'],
                EPPN => ['cecilia@sead-idp.local'],
                DISPLAY_NAME => ['Cecilia Carlsson'],
                GIVEN_NAME => ['Cecilia'],
                SURNAME => ['Carlsson'],
                MAIL => ['cecilia.carlsson@sead-idp.local'],
                SCOPED_AFFILIATION => [
                    'member@sead-idp.local', 'student@sead-idp.local',
                    'employee@sead-idp.local', 'affiliate@sead-idp.local',
                ],
                HOME_ORGANIZATION => ['sead-idp.local'],
            ],
            // A non-ASCII name, to exercise the header encoding
            'asa:asa' => [
                SUBJECT_ID => ['asa@sead-idp.local'],
                EPPN => ['asa@sead-idp.local'],
                DISPLAY_NAME => ['Åsa Öberg-Ström'],
                GIVEN_NAME => ['Åsa'],
                SURNAME => ['Öberg-Ström'],
                MAIL => ['asa.oberg-strom@sead-idp.local'],
                SCOPED_AFFILIATION => ['member@sead-idp.local'],
                HOME_ORGANIZATION => ['sead-idp.local'],
            ],
            // No subject-id, only eduPersonPrincipalName, to exercise the fallback
            'david:david' => [
                EPPN => ['david@sead-idp.local'],
                DISPLAY_NAME => ['David Dahl'],
                GIVEN_NAME => ['David'],
                SURNAME => ['Dahl'],
                MAIL => ['david.dahl@sead-idp.local'],
                SCOPED_AFFILIATION => ['member@sead-idp.local'],
                HOME_ORGANIZATION => ['sead-idp.local'],
            ],
        ],
    ],
];
