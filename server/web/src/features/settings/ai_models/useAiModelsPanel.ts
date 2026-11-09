'use client';

import { useEffect, useState } from 'react';
import {
  connectAiLlm,
  getAiAssistant,
  getAiLlm,
  getAiPresets,
  getAiWebSearch,
  putAiAssistant,
  putAiLlm,
  putAiWebSearch,
  testAiLlm,
  type AiAssistantSkillGroup,
  type AiAssistantToolMeta,
  type AiLlmConfig,
  type AiPresets,
} from '@/lib/api';
import {
  testResultText,
  usePanelAction,
} from '@/hooks/usePanelAction';
import {
  DEFAULT_ASSISTANT_TOOLS,
  DEFAULT_SKILL_GROUPS,
  DEFAULT_TOOL_META,
  LLM_BASE_DEFAULT,
  LLM_MODEL_DEFAULT,
  type AiTab,
} from './helpers';

export type AiModelsPanelState = ReturnType<typeof useAiModelsPanel>;

export function useAiModelsPanel({ onBack }: { onBack: () => void }) {
  const [tab, setTab] = useState<AiTab>('model');
  const [presets, setPresets] = useState<AiPresets | null>(null);

  const [llmEnabled, setLlmEnabled] = useState(true);
  const [llmSource, setLlmSource] = useState('custom');
  const [llmBaseUrl, setLlmBaseUrl] = useState(LLM_BASE_DEFAULT);
  const [llmModel, setLlmModel] = useState(LLM_MODEL_DEFAULT);
  const [llmApiKey, setLlmApiKey] = useState('');
  const [llmHint, setLlmHint] = useState('');
  const [llmFromEnv, setLlmFromEnv] = useState(false);
  const [llmShowKey, setLlmShowKey] = useState(true);
  const [llmPostProcess, setLlmPostProcess] = useState('');
  const [llmHeaders, setLlmHeaders] = useState('');
  const [llmTimeout, setLlmTimeout] = useState('30');
  const [llmAdvanced, setLlmAdvanced] = useState(false);
  const [modelList, setModelList] = useState<string[]>([]);
  const [connectHint, setConnectHint] = useState('');

  const [webEnabled, setWebEnabled] = useState(false);
  const [webProvider, setWebProvider] = useState('searxng');
  const [webBaseUrl, setWebBaseUrl] = useState('http://192.168.2.38:8085');
  const [webApiKey, setWebApiKey] = useState('');
  const [webHint, setWebHint] = useState('');
  const [webShowKey, setWebShowKey] = useState(true);
  const [assistantTools, setAssistantTools] = useState<Record<string, boolean>>(DEFAULT_ASSISTANT_TOOLS);
  const [skillGroups, setSkillGroups] = useState<AiAssistantSkillGroup[]>(DEFAULT_SKILL_GROUPS);
  const [toolMeta, setToolMeta] = useState<AiAssistantToolMeta[]>(DEFAULT_TOOL_META);
  const [assistantModel, setAssistantModel] = useState('');
  const [assistantSystemPrompt, setAssistantSystemPrompt] = useState('');

  // onConnect*/onDownload* 的 catch 落到各自的 hint 变量而非 msg，故保留 setBusy 手动管理
  const { msg, setMsg, busy, setBusy, run } = usePanelAction();

  function applyLlm(llm: AiLlmConfig) {
    setLlmEnabled(llm.enabled !== false);
    setLlmSource(llm.chatCompletionSource || 'custom');
    setLlmBaseUrl(llm.baseUrl || LLM_BASE_DEFAULT);
    setLlmModel(llm.model || LLM_MODEL_DEFAULT);
    setModelList(llm.models || []);
    setLlmHint(llm.apiKeyHint || '');
    setLlmFromEnv(Boolean(llm.fromEnvKey || llm.fromEnv));
    setLlmShowKey(!llm.configured || Boolean(llm.fromEnvKey));
    setLlmPostProcess(llm.promptPostProcessing || '');
    setLlmHeaders(llm.customIncludeHeaders || '');
    setLlmTimeout(String(llm.timeoutSec || 30));
  }

  useEffect(() => {
    void (async () => {
      try {
        const [llm, p, web, assistant] = await Promise.all([
          getAiLlm(),
          getAiPresets(),
          getAiWebSearch(),
          getAiAssistant(),
        ]);
        setPresets(p);
        applyLlm(llm);
        setWebEnabled(Boolean(web.enabled));
        setWebProvider(web.provider || 'searxng');
        setWebBaseUrl(web.baseUrl || 'http://192.168.2.38:8085');
        setWebHint(web.apiKeyHint || '');
        setWebShowKey(web.provider === 'searxng' ? false : !web.configured || Boolean(web.fromEnv));
        setAssistantTools({ ...DEFAULT_ASSISTANT_TOOLS, ...(assistant.tools || {}) });
        setAssistantModel(assistant.model || '');
        setAssistantSystemPrompt(assistant.systemPrompt || '');
        if (assistant.skillGroups?.length) setSkillGroups(assistant.skillGroups);
        if (assistant.toolMeta?.length) setToolMeta(assistant.toolMeta);
      } catch (e) {
        setMsg(e instanceof Error ? e.message : '读取失败');
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function llmBody() {
    const timeout = parseInt(llmTimeout, 10);
    return {
      enabled: llmEnabled,
      chatCompletionSource: llmSource,
      apiMode: 'chat',
      baseUrl: llmBaseUrl.trim(),
      model: llmModel.trim(),
      apiKey: llmApiKey.trim(),
      promptPostProcessing: llmPostProcess,
      customIncludeHeaders: llmHeaders.trim(),
      timeoutSec: Number.isFinite(timeout) ? timeout : 30,
    };
  }

  function switchTab(next: AiTab) {
    setTab(next);
    setMsg('');
  }

  function onLlmSourceChange(value: string) {
    setLlmSource(value);
    const preset = presets?.chatSources.find((x) => x.value === value);
    if (preset?.baseUrl) setLlmBaseUrl(preset.baseUrl);
  }

  async function onConnectLlm() {
    setBusy(true);
    setMsg('');
    setConnectHint('');
    try {
      const r = await connectAiLlm({
        baseUrl: llmBaseUrl.trim(),
        apiKey: llmApiKey.trim() || undefined,
        customIncludeHeaders: llmHeaders.trim() || undefined,
      });
      setModelList(r.models);
      setConnectHint(r.message || `已拉取 ${r.modelCount} 个模型`);
    } catch (e) {
      setModelList([]);
      setConnectHint(e instanceof Error ? e.message : '连接失败');
    } finally {
      setBusy(false);
    }
  }

  async function onTestLlm() {
    await run('测试失败', async () => {
      const r = await testAiLlm(llmBody());
      setMsg(testResultText(r, '聊天模型正常', '失败'));
    });
  }

  async function onSaveLlm() {
    await run('保存失败', async () => {
      const next = await putAiLlm(llmBody());
      applyLlm(next);
      setLlmApiKey('');
      setMsg('聊天模型已保存');
    });
  }

  function setToolEnabled(id: string, on: boolean) {
    setAssistantTools((prev) => {
      const next = { ...prev, [id]: on };
      if (id === 'web_search' && on && !webEnabled) setWebEnabled(true);
      return next;
    });
  }

  function setSkillEnabled(groupId: string, on: boolean) {
    const ids = toolMeta.filter((t) => t.group === groupId).map((t) => t.id);
    setAssistantTools((prev) => {
      const next = { ...prev };
      for (const id of ids) next[id] = on;
      return next;
    });
    if (groupId === 'web') {
      if (on && !webEnabled) setWebEnabled(true);
      if (!on) setWebEnabled(false);
    }
  }

  function skillOn(groupId: string): boolean {
    const ids = toolMeta.filter((t) => t.group === groupId).map((t) => t.id);
    if (!ids.length) return false;
    return ids.some((id) => assistantTools[id] !== false);
  }

  async function onSaveAssistant() {
    await run('保存失败', async () => {
      const webToolOn = assistantTools.web_search !== false;
      await putAiWebSearch({
        enabled: webEnabled && webToolOn,
        provider: webProvider,
        apiKey: webProvider === 'searxng' ? undefined : webApiKey.trim(),
        baseUrl: webBaseUrl.trim(),
      });
      await putAiAssistant({
        model: assistantModel.trim(),
        systemPrompt: assistantSystemPrompt,
        tools: assistantTools,
      });
      const web = await getAiWebSearch();
      setWebHint(web.apiKeyHint || '');
      setWebBaseUrl(web.baseUrl || webBaseUrl);
      setWebShowKey(web.provider === 'searxng' ? false : !web.configured || Boolean(web.fromEnv));
      setWebApiKey('');
      setMsg('Agent 设置已保存');
    });
  }

  const chatSources = presets?.chatSources || [];
  const postOptions = presets?.promptPostProcessing || [];
  const webProviders = presets?.webSearchProviders || [
    { value: 'searxng', label: 'SearXNG（自建免费）' },
    { value: 'serper', label: 'Serper (Google)' },
    { value: 'brave', label: 'Brave Search' },
  ];
  const isSearxng = webProvider === 'searxng';

  const llmConfigured = Boolean(llmHint || llmFromEnv);
  const llmStatusText = !llmEnabled
    ? '已关闭'
    : llmFromEnv
      ? '环境变量'
      : llmConfigured
        ? '已配置'
        : '未配置';
  const llmStatusTone =
    !llmEnabled ? 'mute' : llmConfigured || llmFromEnv ? 'ok' : 'warn';

  return {
    onBack,
    tab,
    switchTab,
    presets,
    llmEnabled,
    setLlmEnabled,
    llmSource,
    llmBaseUrl,
    setLlmBaseUrl,
    llmModel,
    setLlmModel,
    llmApiKey,
    setLlmApiKey,
    llmHint,
    llmFromEnv,
    llmShowKey,
    setLlmShowKey,
    llmPostProcess,
    setLlmPostProcess,
    llmHeaders,
    setLlmHeaders,
    llmTimeout,
    setLlmTimeout,
    llmAdvanced,
    setLlmAdvanced,
    modelList,
    connectHint,
    webEnabled,
    setWebEnabled,
    webProvider,
    setWebProvider,
    webBaseUrl,
    setWebBaseUrl,
    webApiKey,
    setWebApiKey,
    webHint,
    webShowKey,
    setWebShowKey,
    assistantTools,
    skillGroups,
    toolMeta,
    assistantModel,
    setAssistantModel,
    assistantSystemPrompt,
    setAssistantSystemPrompt,
    msg,
    setMsg,
    busy,
    onLlmSourceChange,
    onConnectLlm,
    onTestLlm,
    onSaveLlm,
    setToolEnabled,
    setSkillEnabled,
    skillOn,
    onSaveAssistant,
    applyLlm,
    chatSources,
    postOptions,
    webProviders,
    isSearxng,
    llmConfigured,
    llmStatusText,
    llmStatusTone,
  };
}
