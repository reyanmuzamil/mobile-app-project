import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/validators.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final form_key = GlobalKey<FormState>();
  final email_controller = TextEditingController();
  final password_controller = TextEditingController();
  bool is_loading = false;
  bool hide_password = true;
  String? error_message;

  @override
  void dispose() {
    this.email_controller.dispose();
    this.password_controller.dispose();
    super.dispose();
  }

  Widget build_button_child() {
    if (this.is_loading) {
      return const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Text('Log in');
  }

  IconData get_visibility_icon() {
    if (this.hide_password) {
      return Icons.visibility_off;
    }
    return Icons.visibility;
  }

  VoidCallback? get_submit_handler() {
    if (this.is_loading) {
      return null;
    }
    return this.submit;
  }

  Future<void> submit() async {
    if (!this.form_key.currentState!.validate()) {
      return;
    }
    setState(() {
      this.is_loading = true;
      this.error_message = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: this.email_controller.text.trim(),
        password: this.password_controller.text,
      );
    } on AuthException catch (error) {
      setState(() {
        this.error_message = error.message;
      });
    } catch (error) {
      setState(() {
        this.error_message = 'Something went wrong. Please try again.';
      });
    }
    if (mounted) {
      setState(() {
        this.is_loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: this.form_key,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.public, size: 72),
                    const SizedBox(height: 16),
                    Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: this.email_controller,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: validate_email,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: this.password_controller,
                      obscureText: this.hide_password,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(this.get_visibility_icon()),
                          onPressed: () {
                            setState(() {
                              this.hide_password = !this.hide_password;
                            });
                          },
                        ),
                      ),
                      validator: validate_password,
                    ),
                    if (this.error_message != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        this.error_message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ForgotPasswordScreen(),
                            ),
                          );
                        },
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: this.get_submit_handler(),
                      child: this.build_button_child(),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SignUpScreen(),
                          ),
                        );
                      },
                      child: const Text("Don't have an account? Sign up"),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}