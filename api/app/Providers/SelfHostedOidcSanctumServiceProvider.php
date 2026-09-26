<?php

namespace App\Providers;

use Illuminate\Support\ServiceProvider;

/**
 * Appends self-hosted OIDC connection route names to the Sanctum allowlist
 * without editing upstream config/sanctum-routes.php.
 */
class SelfHostedOidcSanctumServiceProvider extends ServiceProvider
{
    private const OIDC_SANCTUM_ROUTES = [
        'open.workspaces.oidc-connections.index',
        'open.workspaces.oidc-connections.store',
        'open.workspaces.oidc-connections.update',
    ];

    public function boot(): void
    {
        $allowed = config('sanctum-routes.allowed', []);
        config([
            'sanctum-routes.allowed' => array_values(array_unique([
                ...$allowed,
                ...self::OIDC_SANCTUM_ROUTES,
            ])),
        ]);
    }
}
