<?php

use Illuminate\Support\Facades\Config;

it('returns the upstream version and sha release id as plain text', function () {
    Config::set('app.docker_version', 'v2.5.0');
    Config::set('app.docker_revision', 'abcdef0123456789abcdef0123456789abcdef01');

    $response = $this->get('/v');

    $response->assertOk()
        ->assertHeader('Content-Type', 'text/plain; charset=UTF-8')
        ->assertHeader('Cache-Control', 'no-store, private')
        ->assertContent("v2.5.0\nsha-abcdef0123456789abcdef0123456789abcdef01\n");
});

it('falls back to unknown when version values are missing', function () {
    Config::set('app.docker_version', null);
    Config::set('app.docker_revision', null);

    $response = $this->get('/v');

    $response->assertOk()
        ->assertContent("unknown\nunknown\n");
});

it('keeps an existing sha- prefix on the revision', function () {
    Config::set('app.docker_version', 'v2.5.0');
    Config::set('app.docker_revision', 'sha-abcdef0123456789abcdef0123456789abcdef01');

    $response = $this->get('/v');

    $response->assertOk()
        ->assertContent("v2.5.0\nsha-abcdef0123456789abcdef0123456789abcdef01\n");
});
