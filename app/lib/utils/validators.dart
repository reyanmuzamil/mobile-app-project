String? validate_email(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Email is required';
  }
  final pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  if (!pattern.hasMatch(value.trim())) {
    return 'Enter a valid email address';
  }
  return null;
}

String? validate_password(String? value) {
  if (value == null || value.isEmpty) {
    return 'Password is required';
  }
  if (value.length < 6) {
    return 'Password must be at least 6 characters';
  }
  return null;
}