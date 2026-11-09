'use client';

import { Switch } from '@/components/ui/switch';
import type { PluginConfigField } from '@/lib/api';

export function ConfigEditor({
  fields,
  values,
  savedKeys = [],
  onChange,
}: {
  fields: PluginConfigField[];
  values: Record<string, string>;
  savedKeys?: string[];
  onChange: (key: string, value: string) => void;
}) {
  if (!fields.length) {
    return <p className="stremio-hero__note">该插件没有声明配置项。</p>;
  }
  return (
    <section className="app-section">
      <div className="app-section-body">
        {fields.map((field) => {
          const value = values[field.key] ?? field.default ?? '';
          if (field.type === 'boolean') {
            return (
              <div key={field.key} className="settings-kv">
                <span className="settings-kv__key">{field.title}</span>
                <Switch
                  checked={value === 'true'}
                  onCheckedChange={(v) => onChange(field.key, v ? 'true' : 'false')}
                />
              </div>
            );
          }
          if (field.type === 'select') {
            return (
              <label key={field.key} className="app-field app-field--stack">
                <span className="app-label">{field.title}</span>
                <select
                  className="allow-select"
                  value={value}
                  onChange={(e) => onChange(field.key, e.target.value)}
                >
                  <option value="">未设置</option>
                  {(field.options || []).map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
                {field.description ? (
                  <span className="app-hint">{field.description}</span>
                ) : null}
              </label>
            );
          }
          if (field.type === 'textarea') {
            return (
              <label key={field.key} className="app-field app-field--stack">
                <span className="app-label">{field.title}</span>
                <textarea
                  className="allow-select"
                  rows={3}
                  value={value}
                  onChange={(e) => onChange(field.key, e.target.value)}
                />
                {field.description ? (
                  <span className="app-hint">{field.description}</span>
                ) : null}
              </label>
            );
          }
          return (
            <label key={field.key} className="app-field app-field--stack">
              <span className="app-label">{field.title}</span>
              <input
                className="allow-select"
                type={field.type === 'password' ? 'password' : field.type === 'number' ? 'number' : 'text'}
                placeholder={
                  field.type === 'password' && savedKeys.includes(field.key)
                    ? '已保存，留空不改'
                    : field.required
                      ? '必填'
                      : '可选'
                }
                value={value}
                onChange={(e) => onChange(field.key, e.target.value)}
                autoCapitalize="off"
                autoComplete={field.type === 'password' ? 'new-password' : 'off'}
                spellCheck={false}
              />
              {field.description ? (
                <span className="app-hint">{field.description}</span>
              ) : null}
            </label>
          );
        })}
      </div>
    </section>
  );
}
