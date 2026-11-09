'use client';

import { Switch } from '@/components/ui/switch';
import { AppFootnote } from '@/components/ui/AppMsg';
import { getAiLlm } from '@/lib/api';
import { ChatPresetsSection } from '../ChatPresetsSection';
import { FormCard, SettingRow } from './ui';
import type { AiModelsPanelState } from './useAiModelsPanel';

const CAPABILITY_SECTIONS = [
  { key: 'search', label: '检索', groupIds: ['media', 'av'] },
  { key: 'resource', label: '资源', groupIds: ['warehouse', 'magnet', 'stream'] },
  { key: 'cloud', label: '网盘', groupIds: ['cloud'] },
  { key: 'web', label: '网络搜索', groupIds: ['web'] },
];

export function AiAgentTab({ p }: { p: AiModelsPanelState }) {
  const {
    assistantModel,
    setAssistantModel,
    applyLlm,
    modelList,
    assistantSystemPrompt,
    setAssistantSystemPrompt,
    skillGroups,
    toolMeta,
    skillOn,
    setSkillEnabled,
    assistantTools,
    setToolEnabled,
    busy,
    webEnabled,
    setWebEnabled,
    webProvider,
    setWebProvider,
    webProviders,
    webBaseUrl,
    setWebBaseUrl,
    webHint,
    webShowKey,
    setWebShowKey,
    webApiKey,
    setWebApiKey,
    isSearxng,
    onSaveAssistant,
  } = p;

  return (
    <>
      <ul className="settings-group">
        <li>
          <div className="settings-kv">
            <span className="settings-kv__key">名称</span>
            <span className="settings-kv__val">智能搜片助手</span>
          </div>
        </li>
        <li>
          <div className="settings-kv">
            <span className="settings-kv__key">描述</span>
            <span className="settings-kv__val">多源检索与整合回答</span>
          </div>
        </li>
      </ul>

      <p className="settings-group-label">模型</p>
      <FormCard>
        <SettingRow label="绑定模型">
          {modelList.length > 0 ? (
            <select
              className="allow-select ai-input ai-input--select"
              value={assistantModel}
              onChange={(e) => setAssistantModel(e.target.value)}
              disabled={busy}
            >
              <option value="">跟随模型页</option>
              {modelList.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
              {assistantModel && !modelList.includes(assistantModel) ? (
                <option value={assistantModel}>{assistantModel}（已保存）</option>
              ) : null}
            </select>
          ) : (
            <input
              className="allow-select ai-input"
              placeholder="留空跟随模型页"
              value={assistantModel}
              onChange={(e) => setAssistantModel(e.target.value)}
              disabled={busy}
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
            />
          )}
        </SettingRow>
      </FormCard>
      <AppFootnote>留空表示跟随「模型」页的默认模型。</AppFootnote>

      <p className="settings-group-label">指令</p>
      <FormCard>
        <SettingRow label="系统提示词" stack>
          <textarea
            className="allow-select ai-textarea"
            rows={8}
            placeholder="留空使用内置提示词"
            value={assistantSystemPrompt}
            onChange={(e) => setAssistantSystemPrompt(e.target.value)}
            disabled={busy}
            spellCheck={false}
          />
        </SettingRow>
      </FormCard>

      <p className="settings-group-label">采样参数</p>
      <ChatPresetsSection
        onSamplingApplied={() => {
          void (async () => {
            try {
              applyLlm(await getAiLlm());
            } catch {
              /* ignore */
            }
          })();
        }}
      />

      <p className="settings-group-label">能力</p>
      {CAPABILITY_SECTIONS.map((section) => {
        const groups = section.groupIds.flatMap((id) => {
          const group = skillGroups.find((g) => g.id === id);
          return group ? [group] : [];
        });
        if (!groups.length) return null;
        return (
          <div key={section.key} style={{ marginBottom: 12 }}>
            {groups.map((group) => {
              const tools = toolMeta.filter((t) => t.group === group.id);
              return (
                <ul key={group.id} className="settings-group">
                  <li>
                    <div className="settings-kv">
                      <span className="settings-kv__key">
                        {group.label}
                        <span style={{ display: 'block', fontSize: 12, opacity: 0.65, fontWeight: 400 }}>
                          {group.desc}
                        </span>
                      </span>
                      <Switch
                        checked={skillOn(group.id)}
                        onCheckedChange={(on) => setSkillEnabled(group.id, on)}
                        disabled={busy}
                      />
                    </div>
                  </li>
                  {tools.map((tool) => (
                    <li key={tool.id}>
                      <div className="settings-kv">
                        <span className="settings-kv__key">
                          {tool.label}
                          <span
                            style={{ display: 'block', fontSize: 12, opacity: 0.65, fontWeight: 400 }}
                          >
                            {tool.desc}
                          </span>
                        </span>
                        <Switch
                          checked={assistantTools[tool.id] !== false}
                          onCheckedChange={(on) => setToolEnabled(tool.id, on)}
                          disabled={busy}
                        />
                      </div>
                    </li>
                  ))}
                </ul>
              );
            })}
          </div>
        );
      })}

      {skillOn('web') ? (
        <>
          <p className="settings-group-label">网络搜索服务</p>
          <FormCard>
            <SettingRow label="启用服务">
              <Switch
                checked={webEnabled}
                onCheckedChange={(on) => {
                  setWebEnabled(on);
                  if (on) setToolEnabled('web_search', true);
                }}
                disabled={busy}
              />
            </SettingRow>
            <SettingRow label="服务商">
              <select
                className="allow-select ai-input"
                value={webProvider}
                onChange={(e) => {
                  const v = e.target.value;
                  setWebProvider(v);
                  if (v === 'searxng') {
                    setWebShowKey(false);
                    if (!webBaseUrl.trim()) setWebBaseUrl('http://192.168.2.38:8085');
                  } else {
                    setWebShowKey(true);
                  }
                }}
                disabled={busy || !webEnabled}
              >
                {webProviders.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </SettingRow>
            {isSearxng ? (
              <SettingRow label="服务地址">
                <input
                  className="allow-select ai-input"
                  type="url"
                  placeholder="http://192.168.2.38:8085"
                  value={webBaseUrl}
                  onChange={(e) => setWebBaseUrl(e.target.value)}
                  disabled={busy || !webEnabled}
                  autoCapitalize="off"
                  autoCorrect="off"
                  spellCheck={false}
                />
              </SettingRow>
            ) : webHint && !webShowKey ? (
              <SettingRow label="密钥">
                <div className="ai-key-saved">
                  <span className="allow-select">{webHint}</span>
                  <button
                    type="button"
                    className="settings-inline-action"
                    disabled={busy}
                    onClick={() => setWebShowKey(true)}
                  >
                    更换
                  </button>
                </div>
              </SettingRow>
            ) : (
              <SettingRow label="密钥">
                <input
                  className="allow-select ai-input"
                  type="password"
                  placeholder={webProvider === 'brave' ? 'Brave API Key' : 'Serper API Key'}
                  value={webApiKey}
                  onChange={(e) => setWebApiKey(e.target.value)}
                  disabled={busy || !webEnabled}
                  autoCapitalize="off"
                  autoCorrect="off"
                  spellCheck={false}
                />
              </SettingRow>
            )}
          </FormCard>
        </>
      ) : null}

      <AppFootnote>
        关闭某技能后，小花对话里不会再调用对应工具。网络可选 SearXNG（自建免 Key）或
        Serper / Brave；本地库不依赖外网。
      </AppFootnote>

      <div className="app-actions">
        <button
          type="button"
          className="app-btn-primary"
          style={{ flex: 1 }}
          disabled={busy}
          onClick={() => void onSaveAssistant()}
        >
          保存
        </button>
      </div>
    </>
  );
}
