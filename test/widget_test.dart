import 'package:flutter_test/flutter_test.dart';
import 'package:cinepure/main.dart';

void main() {
  testWidgets('TVM renders private login screen', (tester) async {
    await tester.pumpWidget(const TVMApp());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('TVM'), findsOneWidget);
    expect(find.text('اسم المستخدم'), findsOneWidget);
    expect(find.text('كلمة المرور'), findsOneWidget);
  });
}
