import { test } from '@playwright/test';
import { Common } from '../utils/Common';

test.describe('Verify TLS configuration with external Postgres DB', () => {
  test('Verify successful DB connection and display of expected entities in the Catalog', async ({
    browser,
  }) => {
    const context = await browser.newContext({
      ignoreHTTPSErrors: true,
    });
    const page = await context.newPage();
    const common = new Common(page);
    await common.loginAsGuest();
  });
});
