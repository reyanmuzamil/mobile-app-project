import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/validators.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final form_key = GlobalKey<FormState>();
  final email_controller = TextEditingController();
  bool is_loading = false;
  String? error_message;
  String? success_message;

  @override
  void dispose() {
    this.email_controller.dispose();
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
    return const Text('Send reset link');
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
      this.success_message = null;
    });
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        this.email_controller.text.trim(),
      );
      setState(() {
        this.success_message = 'Reset link sent. Check your email.';
      });
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
      appBar: AppBar(title: const Text('Forgot password')),
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
                    if (this.error_message != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        this.error_message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (this.success_message != null) ...[
                      const SizedBox(height: 12),
                      Text(this.success_message!),
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