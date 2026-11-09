/**
 * AI 大模型设置
 *
 * 由 lib/api.ts 拆分而来；对外统一从 `@/lib/api` 导入，请不要直接引用本文件。
 */
import { apiFetch, parseError } from './client';
import type { Envelope } from './client';

export type AiSamplingConfig = {
  temperature?: number | null;
  topP?: number | null;
  maxTokens?: number | null;
  maxContext?: number | null;
  frequencyPenalty?: number | null;
  presencePenalty?: number | null;
  topK?: number | null;
  minP?: number | null;
  repetitionPenalty?: number | null;
  seed?: number | null;
  n?: number | null;
  streamOpenai?: boolean | null;
  maxContextUnlocked?: boolean | null;
  continuePrefill?: boolean | null;
  squashSystemMessages?: boolean | null;
  showThoughts?: boolean | null;
};

export type AiLlmConfig = {
  enabled?: boolean;
  chatCompletionSource?: string;
  apiMode?: string;
  baseUrl?: string;
  model?: string;
  models?: string[];
  promptPostProcessing?: string;
  customIncludeHeaders?: string;
  customIncludeBody?: string;
  customExcludeBody?: string;
  proxyUrl?: string;
  timeoutSec?: number;
  sampling?: AiSamplingConfig;
  configured?: boolean;
  fromEnv?: boolean;
  fromEnvKey?: boolean;
  apiKeyHint?: string;
  updated_at?: string;
};

export type AiPresetOption = { value: string; label: string; baseUrl?: string; dim?: string };

export type AiPresets = {
  chatSources: AiPresetOption[];
  promptPostProcessing: AiPresetOption[];
  webSearchProviders?: AiPresetOption[];
};

export async function getAiPresets(): Promise<AiPresets> {
  const res = await apiFetch('/settings/ai/presets');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AiPresets>).data;
}

export async function getAiLlm(): Promise<AiLlmConfig> {
  const res = await apiFetch('/settings/ai/llm');
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AiLlmConfig>).data;
}

export async function putAiLlm(body: {
  enabled?: boolean;
  chatCompletionSource?: string;
  apiMode?: string;
  baseUrl?: string;
  model?: string;
  apiKey?: string;
  promptPostProcessing?: string;
  customIncludeHeaders?: string;
  customIncludeBody?: string;
  customExcludeBody?: string;
  proxyUrl?: string;
  timeoutSec?: number;
  sampling?: AiSamplingConfig;
}): Promise<AiLlmConfig> {
  const res = await apiFetch('/settings/ai/llm', {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  return ((await res.json()) as Envelope<AiLlmConfig>).data;
}

export async function connectAiLlm(body: {
  baseUrl?: string;
  apiKey?: string;
  customIncludeHeaders?: string;
  listModels?: boolean;
}): Promise<{ ok: boolean; models: string[]; modelCount: number; message: string }> {
  const res = await apiFetch('/settings/ai/llm/connect', {
    method: 'POST',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{
    ok: boolean;
    models?: string[];
    modelCount?: number;
  }> & { message: string };
  return {
    ok: Boolean(json.data?.ok),
    models: json.data?.models || [],
    modelCount: json.data?.modelCount ?? 0,
    message: json.message || '',
  };
}

export async function testAiLlm(body: {
  enabled?: boolean;
  chatCompletionSource?: string;
  apiMode?: string;
  baseUrl?: string;
  model?: string;
  apiKey?: string;
  promptPostProcessing?: string;
  customIncludeHeaders?: string;
  customIncludeBody?: string;
  customExcludeBody?: string;
  proxyUrl?: string;
  timeoutSec?: number;
  sampling?: AiSamplingConfig;
}): Promise<{ ok: boolean; message: string }> {
  const res = await apiFetch('/settings/ai/llm/test', {
    method: 'POST',
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await parseError(res));
  const json = (await res.json()) as Envelope<{ ok: boolean }> & { message: string };
  return { ok: Boolean(json.data?.ok), message: json.message || '' };
}
