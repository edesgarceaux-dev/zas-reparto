import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/login.dart';
import 'screens/admin/admin_home.dart';
import 'screens/repartidor/repartidor_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    anonKey: Config.supabaseAnonKey,
  );
  runApp(const ZasApp());
}

final supa = Supabase.instance.client;

class ZasApp extends StatelessWidget {
  const ZasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZAS Reparto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE85D04),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

/// Decide qué pantalla mostrar según sesión y rol.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<Map<String, dynamic>?> _cargarPerfil() async {
    final user = supa.auth.currentUser;
    if (user == null) return null;
    return await supa.from('perfiles').select().eq('id', user.id).maybeSingle();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supa.auth.onAuthStateChange,
      builder: (context, snap) {
        final session = supa.auth.currentSession;
        if (session == null) return const LoginScreen();
        return FutureBuilder<Map<String, dynamic>?>(
          future: _cargarPerfil(),
          builder: (context, perfilSnap) {
            if (perfilSnap.connectionState != ConnectionState.done) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            final perfil = perfilSnap.data;
            if (perfil == null) {
              return Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No se encontró tu perfil.'),
                      TextButton(
                        onPressed: () => supa.auth.signOut(),
                        child: const Text('Volver a ingresar'),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (perfil['activo'] == false) {
              return Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Tu cuenta está desactivada.'),
                      TextButton(
                        onPressed: () => supa.auth.signOut(),
                        child: const Text('Salir'),
                      ),
                    ],
                  ),
                ),
              );
            }
            return perfil['rol'] == 'admin'
                ? AdminHome(perfil: perfil)
                : RepartidorHome(perfil: perfil);
          },
        );
      },
    );
  }
}
