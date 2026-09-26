<?php

it('appends OIDC connection routes to the Sanctum allowlist', function () {
    $allowed = config('sanctum-routes.allowed', []);

    expect($allowed)
        ->toContain('open.workspaces.oidc-connections.index')
        ->toContain('open.workspaces.oidc-connections.store')
        ->toContain('open.workspaces.oidc-connections.update');
});
