'use client';

import { PostgresDbPanel, type PostgresDbSpec } from './PostgresDbPanel';
import {
  exportBitmagnetDbBackup,
  getBitmagnetDb,
  listBitmagnetDbBackups,
  putBitmagnetDb,
  testBitmagnetDb,
  uploadImportBitmagnetDbBackup,
} from '@/lib/api';

const BITMAGNET_DB_SPEC: PostgresDbSpec = {
  title: 'Bitmagnet',
  fallbackPort: '5432',
  fallbackDatabase: 'bitmagnet',
  dirHint: 'backups/bitmagnet-db/',
  footnote: '普通用户仅可查看连接状态。Bitmagnet 与色花资源库分开配置。',
  get: getBitmagnetDb,
  put: putBitmagnetDb,
  test: testBitmagnetDb,
  listBackups: listBitmagnetDbBackups,
  exportBackup: exportBitmagnetDbBackup,
  uploadImportBackup: uploadImportBitmagnetDbBackup,
};

export function BitmagnetDbPanel({ onBack }: { onBack: () => void }) {
  return <PostgresDbPanel spec={BITMAGNET_DB_SPEC} onBack={onBack} />;
}
