<?php

namespace App\Providers;

use Illuminate\Support\Facades\Route;
use Illuminate\Support\ServiceProvider;

/**
 * Registers a public plain-text /v endpoint without editing upstream routes.
 */
class SelfHostedVersionEndpointServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        Route::middleware('api')->get('/v', function () {
            $version = config('app.docker_version') ?: 'unknown';
            $revision = config('app.docker_revision') ?: 'unknown';
            if ($revision !== 'unknown' && ! str_starts_with($revision, 'sha-')) {
                $revision = 'sha-'.$revision;
            }

            return response(
                $version."\n".$revision."\n",
                200,
                [
                    'Content-Type' => 'text/plain; charset=UTF-8',
                    'Cache-Control' => 'no-store',
                ]
            );
        })->name('self-hosted.version');
    }
}
