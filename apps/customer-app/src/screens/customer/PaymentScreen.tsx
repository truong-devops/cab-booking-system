import React, { useCallback, useMemo, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { useFocusEffect, useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { Card } from '../../components/common/Card';
import { OutlineButton } from '../../components/common/OutlineButton';
import { PrimaryButton } from '../../components/common/PrimaryButton';
import type { MainStackParamList } from '../../navigation/MainStack';
import { useCustomerStore } from '../../store/customerStore';
import { colors, spacing, typography } from '../../theme/tokens';
import { formatVnd } from '../../utils/format';
import { useToast } from '../../hooks/useToast';
import { listPaymentMethods } from '../../lib/settings-storage';
import { useScreenMetrics } from '../../hooks/useScreenMetrics';
import { useAppPalette } from '../../theme/palette';
import { StateView } from '../../components/common/StateView';
import { SkeletonBlock } from '../../components/common/SkeletonBlock';
import * as rideApi from '../../services/rideApi';

type PaymentCode = 'CASH' | 'CARD' | 'WALLET' | 'VIETQR';

type SelectableMethod = {
  id: string;
  code: PaymentCode;
  label: string;
  isDefault?: boolean;
};

const fallbackMethods: SelectableMethod[] = [
  { id: 'fallback-cash', label: 'Tiền mặt', code: 'CASH', isDefault: true },
  { id: 'fallback-card', label: 'Thẻ', code: 'CARD' },
  { id: 'fallback-wallet', label: 'Ví', code: 'WALLET' }
];

const PaymentScreen = () => {
  const navigation = useNavigation<NativeStackNavigationProp<MainStackParamList>>();
  const { activeRide, completeRidePayment } = useCustomerStore();
  const { push } = useToast();
  const metrics = useScreenMetrics();
  const palette = useAppPalette();

  const [methods, setMethods] = useState<SelectableMethod[]>(fallbackMethods);
  const [selectedMethodId, setSelectedMethodId] = useState<string>(fallbackMethods[0].id);
  const [loading, setLoading] = useState(false);
  const [methodsLoading, setMethodsLoading] = useState(true);
  const [methodsError, setMethodsError] = useState<string | null>(null);
  const [rideSummary, setRideSummary] = useState<rideApi.RideSummary | null>(null);
  const [summaryLoading, setSummaryLoading] = useState(false);
  const [summaryError, setSummaryError] = useState<string | null>(null);

  const loadMethods = useCallback(async () => {
    setMethodsLoading(true);
    setMethodsError(null);

    try {
      const items = await listPaymentMethods();
      const mapped = items
        .filter((item) => ['CASH', 'CARD', 'WALLET', 'VIETQR'].includes(item.type))
        .map((item) => ({
          id: item.id,
          code: item.type as PaymentCode,
          label: item.label || item.type,
          isDefault: item.isDefault
        }));

      const next = mapped.length ? mapped : fallbackMethods;
      setMethods(next);
      const defaultMethod = next.find((item) => item.isDefault) || next[0];
      setSelectedMethodId(defaultMethod.id);
    } catch {
      setMethodsError('Không tải được phương thức thanh toán.');
      setMethods(fallbackMethods);
      setSelectedMethodId(fallbackMethods[0].id);
    } finally {
      setMethodsLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void loadMethods();

      if (!activeRide?.id) return;
      let mounted = true;

      const loadSummary = async () => {
        setSummaryLoading(true);
        setSummaryError(null);

        try {
          const response = await rideApi.getRideSummary(activeRide.id);
          if (!mounted) return;
          setRideSummary(response.data);
        } catch (err: any) {
          if (!mounted) return;
          if (err?.status === 409) {
            setSummaryError('Đang cập nhật tổng cước chuyến...');
          } else {
            setSummaryError('Không tải được tổng cước chính xác.');
          }
        } finally {
          if (mounted) {
            setSummaryLoading(false);
          }
        }
      };

      void loadSummary();

      return () => {
        mounted = false;
      };
    }, [activeRide?.id, loadMethods])
  );

  const summaryAmount = useMemo(() => {
    const amount = rideSummary?.fare?.amount ?? rideSummary?.breakdown?.total;
    if (!Number.isFinite(amount)) return null;
    const rounded = Math.round(amount);
    return rounded > 0 ? rounded : null;
  }, [rideSummary]);

  const displayedAmount = useMemo(() => summaryAmount ?? activeRide?.option.price ?? 0, [activeRide?.option.price, summaryAmount]);

  const selectedMethod = useMemo(() => methods.find((item) => item.id === selectedMethodId) || methods[0], [methods, selectedMethodId]);

  const handlePay = async () => {
    if (!selectedMethod) {
      push('Chưa có phương thức thanh toán hợp lệ', 'danger');
      return;
    }
    try {
      setLoading(true);
      await completeRidePayment(selectedMethod.code, displayedAmount);
      navigation.replace('Rating');
    } catch (err: any) {
      push(err?.message || 'Thanh toán thất bại', 'danger');
    } finally {
      setLoading(false);
    }
  };

  return (
    <View style={[styles.container, { backgroundColor: palette.bg, paddingHorizontal: metrics.horizontalPadding }]}>
      <View style={[styles.contentWrap, { maxWidth: metrics.contentMaxWidth }]}>
        <Text style={[styles.title, { color: palette.text }]}>Thanh toán</Text>

        <Card>
          <Text style={[styles.label, { color: palette.muted }]}>Tổng cước phí</Text>
          <Text style={styles.amount}>{formatVnd(displayedAmount)}</Text>
          {summaryLoading ? (
            <Text style={[styles.note, { color: palette.muted }]}>Đang kiểm tra tổng cước chuyến...</Text>
          ) : summaryError ? (
            <Text style={[styles.note, { color: colors.red }]}>{summaryError}</Text>
          ) : null}
        </Card>

        <Card style={styles.methodCard}>
          <Text style={[styles.label, { color: palette.muted }]}>Phương thức thanh toán</Text>

          {methodsLoading ? (
            <View style={styles.skeletonList}>
              <SkeletonBlock height={42} />
              <SkeletonBlock height={42} />
              <SkeletonBlock height={42} />
            </View>
          ) : methodsError ? (
            <StateView type="error" title="Không tải được phương thức" message={methodsError} actionLabel="Thử lại" onAction={() => void loadMethods()} />
          ) : (
            methods.map((item) =>
              item.id === selectedMethod?.id ? (
                <PrimaryButton key={item.id} title={`${item.label} (đang chọn)`} onPress={() => setSelectedMethodId(item.id)} />
              ) : (
                <OutlineButton key={item.id} title={item.label} onPress={() => setSelectedMethodId(item.id)} />
              )
            )
          )}
        </Card>

        <PrimaryButton title={loading ? 'Đang xử lý...' : 'Thanh toán'} onPress={handlePay} disabled={loading || methodsLoading} />
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, paddingTop: spacing.xl, paddingBottom: spacing.xl },
  contentWrap: { width: '100%', alignSelf: 'center', gap: spacing.md },
  title: { ...typography.title },
  label: { ...typography.body },
  amount: { ...typography.title, color: colors.brand700 },
  methodCard: { gap: spacing.sm },
  skeletonList: { gap: spacing.sm },
  note: { ...typography.body, marginTop: spacing.xs }
});

export default PaymentScreen;
