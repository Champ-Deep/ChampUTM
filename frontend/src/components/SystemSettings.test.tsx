import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SystemSettings } from './SystemSettings';
import type { MaxMindUsage } from '../api/system';

const maxmind = vi.fn();
vi.mock('../api/system', () => ({ systemApi: { maxmind: (d?: number) => maxmind(d) } }));

function usage(over: Partial<MaxMindUsage> = {}): MaxMindUsage {
  return {
    configured: true,
    endpoint: 'insights',
    queries_remaining: 24879,
    balance_as_of: new Date().toISOString(),
    status: 'ok',
    warn_threshold: 5000,
    critical_threshold: 1000,
    lookups_today: 12,
    lookups_window: 400,
    window_days: 30,
    errors_window: 0,
    avg_daily: 200,
    days_left: 124,
    projected_exhaustion: '2027-01-09',
    lifetime_lookups: 400,
    lifetime_errors: 0,
    unit_price_usd: 0,
    spend_window_usd: null,
    spend_lifetime_usd: null,
    daily: [
      { day: '2026-09-06', lookups: 100, errors: 0, queries_remaining: 25000 },
      { day: '2026-09-07', lookups: 300, errors: 0, queries_remaining: 24879 },
    ],
    ...over,
  };
}

function renderPanel() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <SystemSettings />
    </QueryClientProvider>,
  );
}

describe('SystemSettings — MaxMind credits', () => {
  beforeEach(() => maxmind.mockReset());

  it('shows the balance, burn rate and run-out date when healthy', async () => {
    maxmind.mockResolvedValue(usage());
    renderPanel();

    expect(await screen.findByText('24,879')).toBeInTheDocument();
    expect(screen.getByText('Healthy')).toBeInTheDocument();
    expect(screen.getByText('200/day')).toBeInTheDocument();
    expect(screen.getByText('124d')).toBeInTheDocument();
    // no scare banner while healthy
    expect(screen.queryByText(/Top up at maxmind.com/)).not.toBeInTheDocument();
  });

  it('warns, and says when the credits run out, once below the threshold', async () => {
    maxmind.mockResolvedValue(
      usage({ queries_remaining: 900, status: 'critical', days_left: 4, projected_exhaustion: '2026-09-11' }),
    );
    renderPanel();

    expect(await screen.findByText('Top up now')).toBeInTheDocument();
    expect(screen.getByText(/Top up at maxmind.com/)).toBeInTheDocument();
    expect(screen.getByText(/they run out around/)).toBeInTheDocument();
  });

  it('explains itself instead of showing zeroes when the service is off', async () => {
    maxmind.mockResolvedValue(usage({ configured: false }));
    renderPanel();

    expect(await screen.findByText(/MaxMind web service is not configured/)).toBeInTheDocument();
    expect(screen.queryByText('24,879')).not.toBeInTheDocument();
  });

  it('shows dollars only once a unit price is configured', async () => {
    maxmind.mockResolvedValue(usage({ unit_price_usd: 0.002, spend_window_usd: 0.8, spend_lifetime_usd: 0.8 }));
    renderPanel();

    expect(await screen.findByText('Spend (lifetime)')).toBeInTheDocument();
    expect(screen.getAllByText('$0.80').length).toBeGreaterThan(0);
    expect(screen.getByText('$0.0020')).toBeInTheDocument();
  });
});
