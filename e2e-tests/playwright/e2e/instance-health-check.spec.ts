import { test, expect } from '@playwright/test';

test('Application health check', async ({ request }) => {
  console.log(`Url instance: ${process.env.BASE_URL}/healthcheck`);
  const healthCheckEndpoint = `${process.env.BASE_URL}/healthcheck`;

  const response = await request.get(healthCheckEndpoint);

  const responseBody = await response.json();

  expect(response.status()).toBe(200);

  expect(responseBody).toHaveProperty('status', 'ok');
});
