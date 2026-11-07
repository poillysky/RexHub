'use client';

import type { ReactNode } from 'react';
import { PostgresDbPanel, type PostgresDbSpec } from './PostgresDbPanel';
import {
  exportResourceDbBackup,
  getResourceDb,
  listResourceDbBackups,
  putResourceDb,
  testResourceDb,
  uploadImportResourceDbBackup,
} from '@/lib/api';

const RESOURCE_DB_SPEC: PostgresDbSpec = {
  title: '色花资源库',
  fallbackPort: '5435',
  fallbackDatabase: 'ed2k',
  dirHint: 'backups/resource-db/',
  footnote: '普通用户仅可查看连接状态。色花资源库与 Bitmagnet 分开配置。',
  get: getResourceDb,
  put: putResourceDb,
  test: testResourceDb,
  listBackups: listResourceDbBackups,
  exportBackup: exportResourceDbBackup,
  uploadImportBackup: uploadImportResourceDbBackup,
};

export function ResourceDbPanel({
  onBack,
  title,
  extraRows,
}: {
  onBack: () => void;
  title?: string;
  extraRows?: ReactNode;
}) {
  return (
    <PostgresDbPanel
      spec={RESOURCE_DB_SPEC}
      onBack={onBack}
      title={title}
      extraRows={extraRows}
    />
  );
}
