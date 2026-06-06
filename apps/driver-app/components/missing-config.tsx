import { SafeAreaView, StyleSheet, Text, View } from 'react-native';
import { palette } from '@/lib/theme';

export function MissingConfig() {
  return (
    <SafeAreaView style={styles.safe}>
      <View style={styles.card}>
        <Text style={styles.title}>Thiếu cấu hình API</Text>
        <Text style={styles.body}>Ứng dụng cần biến môi trường EXPO_PUBLIC_API_BASE_URL để gọi Backend.</Text>
        <Text style={styles.code}>EXPO_PUBLIC_API_BASE_URL=http://&lt;IP_MAY&gt;:42100</Text>
        <Text style={styles.note}>Sau khi cập nhật .env, hãy restart Expo (Ctrl+C rồi chạy lại).</Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: palette.background,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24
  },
  card: {
    backgroundColor: palette.card,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: palette.border,
    padding: 20,
    gap: 12
  },
  title: {
    fontSize: 20,
    fontWeight: '700',
    color: palette.text
  },
  body: {
    color: palette.muted,
    lineHeight: 20
  },
  code: {
    fontFamily: 'Courier',
    backgroundColor: palette.redSoft,
    padding: 10,
    borderRadius: 8,
    color: palette.redDark
  },
  note: {
    color: palette.muted,
    fontSize: 12
  }
});
