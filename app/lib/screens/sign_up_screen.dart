import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/validators.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final form_key = GlobalKey<FormState>();
  final email_controller = TextEditingController();
  final password_controller = TextEditingController();
  final confirm_controller = TextEditingController();
  bool is_loading = false;
  String? error_message;

  @override
  void dispose() {
    this.email_controller.dispose();
    this.password_controller.dispose();
    this.confirm_controller.dispose();
    super.dispose();
  }

  String? validate_confirm(String? value) {
    if (value != this.password_controller.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  Widget build_button_child() {
    if (this.is_loading) {
      return const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Text('Create account');
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
      final response = await Supabase.instance.client.auth.signUp(
        email: this.email_controller.text.trim(),
        password: this.password_controller.text,
        emailRedirectTo: 'io.supabase.sheapp://login-callback/',
      );
      if (!mounted) {
        return;
      }
      if (response.session != null) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Check your email to confirm your account')),
      );
      Navigator.of(context).pop();
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
      appBar: AppBar(title: const Text('Sign up')),
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
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: validate_password,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: this.confirm_controller,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: this.validate_confirm,
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
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: this.get_submit_handler(),
                      child: this.build_button_child(),
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