'use client';

import { ArrowDown, CircleCheck, Cloud, HardDrive, TriangleAlert } from 'lucide-react';
import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import { formatBytes } from './format';
import type { P115PanelState } from './useP115Panel';

type Tone = 'scan' | 'cloud' | 'local' | 'check' | 'done' | 'fail';

function Node({
  tone,
  title,
  sub,
}: {
  tone: Tone;
  title: string;
  sub?: string;
}) {
  return (
    <div className={cn('p115-flow__node', `is-${tone}`)}>
      <span className="p115-flow__dot" aria-hidden />
      <span className="p115-flow__body">
        <span className="p115-flow__title allow-select">{title}</span>
        {sub ? <span className="p115-flow__sub allow-select">{sub}</span> : null}
      </span>
    </div>
  );
}

function Link({ label }: { label?: string }) {
  return (
    <div className="p115-flow__link" aria-hidden>
      <ArrowDown size={13} strokeWidth={2.2} />
      {label ? <span>{label}</span> : null}
    </div>
  );
}

function Lane({
  kind,
  icon,
  title,
  note,
  steps,
}: {
  kind: 'cloud' | 'local';
  icon: ReactNode;
  title: string;
  note: string;
  steps: Array<{ title: string; sub?: string; stage?: string }>;
}) {
  return (
    <div className={cn('p115-flow__lane', `is-${kind}`)}>
      <p className="p115-flow__lane-head">
        <span className="p115-flow__lane-icon" aria-hidden>
          {icon}
        </span>
        {title}
      </p>
      <p className="p115-flow__lane-note allow-select">{note}</p>
      {steps.map((step, idx) => (
        <div key={`${step.stage || ''}${step.title}`}>
          {step.stage ? <p className="p115-flow__stage">{step.stage}</p> : null}
          {idx > 0 && !step.stage ? <Link /> : null}
          <Node tone={kind} title={step.title} sub={step.sub} />
        </div>
      ))}
    </div>
  );
}

export function P115FlowTab({ p }: { p: P115PanelState }) {
  const status = p.extractStatus;
  const current = status?.current ?? null;
  const counts = status?.counts;
  const running = Boolean(status?.running);
  const percent = Math.max(0, Math.min(100, Number(current?.percent) || 0));

  return (
    <div className="p115-flow">
      <section className="p115-console__block">
        <p className="settings-group-label">当前状态</p>
        <div className={cn('p115-flow__live', running ? 'is-run' : 'is-idle')}>
          <p className="p115-flow__live-title allow-select">
            {running ? current?.name || '准备中…' : '队列未运行'}
          </p>
          <p className="p115-flow__live-sub allow-select">
            {running
              ? `${current?.stage || '处理中'}${current?.size ? ` · ${formatBytes(current.size)}` : ''}`
              : '点「解压」页签的「开始解压」才会调度任务'}
          </p>
          {running && current ? (
            <div className="p115-flow__bar" aria-hidden>
              <span style={{ width: `${percent}%` }} />
            </div>
          ) : null}
          <p className="p115-flow__live-meta allow-select">
            {counts && counts.total > 0
              ? `共 ${counts.total} · 完成 ${counts.done} · 失败 ${counts.failed} · 待重试 ${counts.waiting}`
              : '当前没有排队的压缩包'}
          </p>
        </div>
      </section>

      <section className="p115-console__block">
        <p className="settings-group-label">解压流程（两段式）</p>
        <div className="p115-flow__canvas">
          <Node
            tone="scan"
            title="扫描解压目录"
            sub="只取目标目录第一层的 zip / rar / 7z，不进子文件夹；压缩包名带【密码:xxx】就用它，没带就按配置密码 → 空密码 → 兜底密码"
          />
          <Link />
          <Node
            tone="check"
            title="分拣"
            sub="分卷包直接跳过 · 超过 20GB 或账号非会员改走本地 · 其余走云端"
          />
          <Link label="双通道，各一个串行 worker" />

          <div className="p115-flow__lanes">
            <Lane
              kind="cloud"
              icon={<Cloud size={13} strokeWidth={2.2} />}
              title="云端解压（115 会员）"
              note="在网盘侧解压，不占本地下行带宽"
              steps={[
                {
                  stage: '阶段一 · 推送预解析（push_extract）',
                  title: '带候选密码提交 push_extract',
                  sub: '密码顺序：压缩包名【密码:xxx】→ 配置密码（有配置时）→ 空密码 → 兜底密码；115 同步校验，不对立即回 unzip_status=6',
                },
                {
                  title: '轮询 unzip_status',
                  sub: '0 未解压 · 1 解压中 · 4 就绪 · 6 失败；没就绪就固定等 10 分钟再查，期间先跑别的任务，最长 2 小时',
                },
                {
                  title: 'status = 6 → 密码不对（115 标准返回）',
                  sub: '名字里的密码不对也一样按「配置密码 → 空密码 → 兜底密码」继续往下试；全部不对才判失败，不转本地',
                },
                {
                  title: 'status ≠ 4 → 只等待，不实测目录',
                  sub: '115 还在服务器端预解析：固定 10 分钟复查一次，期间先跑别的任务；超过 2 小时改本地',
                },
                {
                  stage: '阶段二 · 提交解压（add_extract_file）',
                  title: 'status = 4 → 预解析就绪',
                  sub: 'extract_info 拿文件清单，创建同名目录后提交解压',
                },
                {
                  title: '固定每 10 秒看一次 percent / bytes',
                  sub: '不再估算 ETA；百分比连续 15 分钟没有任何变化才判停滞',
                },
                {
                  title: '进度字段消失 → 实测产物',
                  sub: '115 完成后不再返回 percent，改为递归统计目标目录大小',
                },
              ]}
            />
            <Lane
              kind="local"
              icon={<HardDrive size={13} strokeWidth={2.2} />}
              title="本地兜底"
              note="云端不可用 / 超 20GB / 非会员时改本地；密码全对不上不会走这里"
              steps={[
                {
                  title: '下载原压缩包',
                  sub: '落到 server/data/p115-extract 工作目录',
                },
                {
                  title: '本地解压',
                  sub: '沿用同一套密码顺序：压缩包名【密码】→ 配置密码 → 空密码 → 兜底密码，逐个试，全部不对才判失败',
                },
                {
                  title: '上传产物到同目录',
                  sub: '保持与原压缩包同级的同名文件夹',
                },
                {
                  title: '统计产物大小',
                  sub: '进入统一的产物核对环节',
                },
              ]}
            />
          </div>

          <Link />
          <Node
            tone="check"
            title="产物核对"
            sub="实测产物 ≥ 原压缩包 98% 才算成功（压缩包头/填充允许 2% 误差）"
          />
          <Link label="不达标：" />
          <Node
            tone="fail"
            title="30 秒后复核 → 仍偏小"
            sub="有产物但偏小 = 云解压不完整，不是密码问题：转本地重解，不删产物、不换密码。零产物才换密码，候选用完直接跳过"
          />
          <Link label="达标：" />
          <Node
            tone="done"
            title="删除原压缩包 → 任务完成"
            sub="核对失败时保留原包，方便排查或重试"
          />
        </div>
      </section>

      <section className="p115-console__block">
        <p className="settings-group-label">关键规则</p>
        <ul className="p115-flow__rules">
          <li>
            <CircleCheck size={13} strokeWidth={2.2} aria-hidden />
            转存时若有密码，会直接写进收到的压缩包标题（xxx【密码:abc】.zip），文件夹则追加在名字末尾；解压扫描读名字即可，产物目录名会自动去掉这个标记。
          </li>
          <li>
            <CircleCheck size={13} strokeWidth={2.2} aria-hidden />
            同一个压缩包可能被中断多次：任务状态落盘，重启后按记录的阶段继续。
          </li>
          <li>
            <TriangleAlert size={13} strokeWidth={2.2} aria-hidden />
            空间不足、格式不支持、非会员这类不可恢复错误不重试，直接判失败或转本地。
          </li>
          <li>
            <TriangleAlert size={13} strokeWidth={2.2} aria-hidden />
            只有产物核对通过才删原包；核对不通过一律保留，避免误删。
          </li>
        </ul>
      </section>
    </div>
  );
}
