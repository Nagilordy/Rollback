import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/syncplay.dart';

// Watch party messages from other Rollbacks: only well-formed ones of the known kinds get
// through, with only the known fields.
void main() {
  test('a normal play/pause message passes, unchanged', () {
    final m = {'t': 'state', 'playing': true, 'pos': 186.4, 'at': 1762530000000, 'by': 'Nagi', 'what': 'play', 'g': 'abc'};
    expect(validDirectMessage(m), m);
  });

  test('the other kinds pass with what they need', () {
    expect(validDirectMessage({'t': 'tick', 'pos': 12.5, 'at': 1}), isNotNull);
    expect(validDirectMessage({'t': 'wait', 'by': 'Jo', 'on': false}), isNotNull);
    expect(validDirectMessage({'t': 'hello', 'by': 'Jo'}), isNotNull);
    expect(validDirectMessage({'t': 'away', 'by': 'Jo'}), isNotNull);
    expect(validDirectMessage({'t': 'bye', 'by': 'Jo'}), isNotNull);
  });

  test('messages from before the room id still pass', () {
    expect(validDirectMessage({'t': 'hello', 'by': 'Jo'})?['g'], isNull);
  });

  test('unknown kinds and non-messages are dropped', () {
    expect(validDirectMessage(null), isNull);
    expect(validDirectMessage('state'), isNull);
    expect(validDirectMessage([1, 2]), isNull);
    expect(validDirectMessage({'t': 'delete-everything'}), isNull);
    expect(validDirectMessage({'t': 3}), isNull);
    expect(validDirectMessage(<String, dynamic>{}), isNull);
  });

  test('wrong types are dropped instead of breaking the player', () {
    expect(validDirectMessage({'t': 'state', 'playing': 'yes', 'pos': 1, 'at': 1}), isNull);
    expect(validDirectMessage({'t': 'state', 'playing': true, 'pos': '1', 'at': 1}), isNull);
    expect(validDirectMessage({'t': 'tick', 'pos': 1, 'at': 'now'}), isNull);
    expect(validDirectMessage({'t': 'wait', 'by': 'Jo', 'on': 1}), isNull);
    expect(validDirectMessage({'t': 'hello', 'by': 42}), isNull);
  });

  test('missing required values are dropped', () {
    expect(validDirectMessage({'t': 'state', 'pos': 1, 'at': 1}), isNull); // playing
    expect(validDirectMessage({'t': 'tick', 'at': 1}), isNull); // pos
    expect(validDirectMessage({'t': 'wait', 'by': 'Jo'}), isNull); // on
  });

  test('impossible values are dropped', () {
    expect(validDirectMessage({'t': 'tick', 'pos': -5, 'at': 1}), isNull);
    expect(validDirectMessage({'t': 'tick', 'pos': 999999, 'at': 1}), isNull);
    expect(validDirectMessage({'t': 'tick', 'pos': double.nan, 'at': 1}), isNull);
    expect(validDirectMessage({'t': 'tick', 'pos': 1, 'at': 0}), isNull);
    expect(validDirectMessage({'t': 'hello', 'by': 'x' * 65}), isNull);
    expect(validDirectMessage({'t': 'state', 'playing': true, 'pos': 1, 'at': 1, 'what': 'x' * 17}), isNull);
  });

  test('unknown extra fields are left out', () {
    final m = validDirectMessage({'t': 'hello', 'by': 'Jo', 'evil': 'payload'});
    expect(m, {'t': 'hello', 'by': 'Jo'});
  });
}
