import { useQuery } from '@tanstack/react-query';
import { AlertTriangle, CheckCircle2, Gauge, HelpCircle, TrendingDown } from 'lucide-react';
import { Badge, Card, CardHeader, CardTitle } from './ui';
import { systemApi } from '../api/system';
import type { MaxMindUsage, SystemStatus } from '../api/system';
import { formatRelative } from '../lib/format';
import { apiErrorDetail } from '../api/_shared';

const STATUS_VARIANT: Record<SystemStatus, 'success' | 'warning' | 'danger' | 'default'> = {
  ok: 'success',
  warning: 'warning',
  critical: 'danger',
  unknown: 'default',
};

const STATUS_LABEL: Record<SystemStatus, string> = {
  ok: 'Healthy',
  warning: 'Running low',
  critical: 'Top up now',
  unknown: 'No data yet',
};

function StatusIcon({ status }: { status: SystemStatus }) {
  const cls = 'h-5 w-5';
  if (status === 'ok') return <CheckCircle2 className={`${cls} text-emerald-600`} />;
  if (status === 'unknown') return <HelpCircle className={`${cls} text-slate-400`} />;
  return <AlertTriangle className={`${cls} ${status === 'critical' ? 'text-red-600' : 'text-amber-600'}`} />;
}

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white px-4 py-3">
      <div className="text-xs text-slate-500">{label}</div>
      <div className="text-xl font-semibold text-slate-900 mt-0.5 tabular-nums">{value}</div>
      {hint && <div className="text-xs text-slate-400 mt-0.5">{hint}</div>}
    </div>
  );
}

function num(n: number | null | undefined): string {
  return typeof n === 'number' ? n.toLocaleString() : '—';
}

function money(n: number | null): string {
  return typeof n === 'number' ? `$${n.toFixed(2)}` : '—';
}

/** Compact daily-usage strip. A sparkline, not a chart — it answers "is the
 *  burn steady or did something spike?" at a glance. */
function UsageStrip({ data }: { data: MaxMindUsage['daily'] }) {
  const peak = Math.max(1, ...data.map((d) => d.lookups));
  if (data.length === 0) {
    return <div className="text-sm text-slate-500">No lookups recorded yet.</div>;
  }
  return (
    <div className="flex items-end gap-0.5 h-16" role="img" aria-label="Daily MaxMind lookups">
      {data.map((d) => (
        <div
          key={d.day}
          title={`${d.day}: ${d.lookups.toLocaleString()} lookups${d.errors ? `, ${d.errors} errors` : ''}`}
          className="flex-1 min-w-[3px] rounded-t bg-brand-purple/70 hover:bg-brand-purple transition-colors"
          style={{ height: `${Math.max(4, (d.lookups / peak) * 100)}%` }}
        />
      ))}
    </div>
  );
}

export function SystemSettings() {
  const { data, isLoading, error } = useQuery<MaxMindUsage>({
    queryKey: ['system', 'maxmind'],
    queryFn: () => systemApi.maxmind(30),
    refetchInterval: 60_000,
  });

  if (isLoading) {
    return <div className="py-8 text-center text-sm text-slate-500">Loading.</div>;
  }

  if (error || !data) {
    return (
      <Card>
        <div className="py-8 text-center text-sm text-slate-500">
          {apiErrorDetail(error) ?? 'Could not load system status.'}
        </div>
      </Card>
    );
  }

  const exhaustion = data.projected_exhaustion
    ? new Date(data.projected_exhaustion).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      })
    : null;

  return (
    <>
      <Card className="mb-6">
        <CardHeader>
          <CardTitle>MaxMind GeoIP credits</CardTitle>
        </CardHeader>

        {!data.configured ? (
          <p className="text-sm text-slate-600">
            The MaxMind web service is not configured, so link and page views fall back to
            local databases. Set the account id and license key to enable VPN detection.
          </p>
        ) : (
          <>
            <div className="flex items-center gap-3 mb-4">
              <StatusIcon status={data.status} />
              <div className="flex-1">
                <div className="flex items-center gap-2">
                  <span className="text-2xl font-semibold text-slate-900 tabular-nums">
                    {num(data.queries_remaining)}
                  </span>
                  <span className="text-sm text-slate-500">queries left</span>
                  <Badge variant={STATUS_VARIANT[data.status]}>{STATUS_LABEL[data.status]}</Badge>
                </div>
                <div className="text-xs text-slate-500 mt-0.5">
                  {data.balance_as_of
                    ? `Reported by MaxMind ${formatRelative(data.balance_as_of)} · ${data.endpoint} endpoint`
                    : 'No balance reported yet — it arrives with the next lookup.'}
                </div>
              </div>
            </div>

            {data.status !== 'ok' && data.status !== 'unknown' && (
              <div className={`mb-4 rounded-lg border p-3 text-sm ${
                data.status === 'critical'
                  ? 'border-red-200 bg-red-50 text-red-800'
                  : 'border-amber-200 bg-amber-50 text-amber-800'
              }`}>
                <TrendingDown className="h-4 w-4 inline mr-1.5 -mt-0.5" />
                Credits are below the {num(
                  data.status === 'critical' ? data.critical_threshold : data.warn_threshold,
                )} threshold
                {exhaustion ? `; at the current rate they run out around ${exhaustion}.` : '.'}{' '}
                Top up at maxmind.com before geo enrichment silently stops.
              </div>
            )}

            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <Stat label="Used today" value={num(data.lookups_today)} />
              <Stat
                label={`Used (${data.window_days}d)`}
                value={num(data.lookups_window)}
                hint={data.errors_window ? `${num(data.errors_window)} failed` : undefined}
              />
              <Stat label="Burn rate" value={`${num(data.avg_daily)}/day`} hint="average of active days" />
              <Stat
                label="Runs out"
                value={data.days_left !== null ? `${num(data.days_left)}d` : '—'}
                hint={exhaustion ?? 'needs a few days of usage'}
              />
            </div>

            <div className="mt-5">
              <div className="flex items-center justify-between mb-2">
                <span className="text-xs font-medium text-slate-500 uppercase tracking-wider">
                  Daily lookups
                </span>
                <span className="text-xs text-slate-400">
                  <Gauge className="h-3 w-3 inline mr-1 -mt-0.5" />
                  last {data.window_days} days
                </span>
              </div>
              <UsageStrip data={data.daily} />
            </div>
          </>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Spend</CardTitle>
        </CardHeader>
        {data.unit_price_usd > 0 ? (
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
            <Stat label={`Spend (${data.window_days}d)`} value={money(data.spend_window_usd)} />
            <Stat label="Spend (lifetime)" value={money(data.spend_lifetime_usd)} />
            <Stat
              label="Unit price"
              value={`$${data.unit_price_usd.toFixed(4)}`}
              hint="per query"
            />
          </div>
        ) : (
          <p className="text-sm text-slate-600">
            Set <code className="text-xs bg-slate-100 px-1 py-0.5 rounded">MAXMIND_UNIT_PRICE_USD</code>{' '}
            to what a query actually costs you (what you paid for the credit pack, divided by the
            queries it contained) and this turns into dollars. Usage so far:{' '}
            <strong>{num(data.lifetime_lookups)}</strong> queries.
          </p>
        )}
      </Card>
    </>
  );
}
