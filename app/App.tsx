import 'react-native-get-random-values';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import db from './db';

export default function App() {
  const { isLoading, error, data } = db.useQuery({ signups: {} });

  const status = isLoading ? 'loading...' : error ? `error: ${error.message}` : `ok — ${data?.signups?.length ?? 0} signups`;

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Yarnia</Text>
      <Text style={[styles.sub, error ? styles.error : null]}>{status}</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0a0a14',
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    color: '#fff',
    fontSize: 32,
    fontWeight: '700',
  },
  sub: {
    color: '#888',
    fontSize: 13,
    marginTop: 8,
  },
  error: {
    color: '#f87171',
  },
});
