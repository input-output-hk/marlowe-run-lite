@smoke
@regression

Feature: As a user, I would like to apply an input on a current contract

    As a user I would like to apply an input on a current contract
    So that I can proceed through the contract

    Scenario Outline: Creating a deposit with a wallet
      Given I configure my <wallet_name> wallet
      And I am on the "home" page
      Then I should see a "heading" with "Choose a wallet" text

      When I authorize my <wallet_name> wallet
      Then I should see a "button" with "Create a contract" text

      When I click the "button" with "Create a contract" text
      And I generate the contract "SimpleDeposit" and write it to "/tmp/deposit.json"
      And I enter the contents of "/tmp/deposit.json" into the "contract-input" field

      When I click the "button" with "Submit contract" text And sign the transaction with <wallet_name> wallet
      Then I should see the first "button" showing "Syncing" text
      And I should see the first "button" showing "Advance" text
      And I should see "Successfully created and submitted the contract. Contract transaction awaits to be included in the blockchain." text

      When I click the first "button" with "Advance" text
      Then I should see a "button" with "Make deposit" text

      When I click the "checkbox" with "Deposit 0.000001 ₳" text
      And I click the "button" with "Make deposit" text And sign the transaction with <wallet_name> wallet
      And I should see "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." text

    Examples:
      | wallet_name |
      | lace        |
      | nami        |

    Scenario Outline: Creating a choice with a wallet
      Given I configure my <wallet_name> wallet
      And I am on the "home" page
      Then I should see a "heading" with "Choose a wallet" text

      When I authorize my <wallet_name> wallet
      Then I should see a "button" with "Create a contract" text

      When I click the "button" with "Create a contract" text
      And I generate the contract "SimpleChoice" and write it to "/tmp/choice.json"
      And I enter the contents of "/tmp/choice.json" into the "contract-input" field

      When I click the "button" with "Submit contract" text And sign the transaction with <wallet_name> wallet
      Then I should see the first "button" showing "Syncing" text
      And I should see the first "button" showing "Advance" text
      And I should see "Successfully created and submitted the contract. Contract transaction awaits to be included in the blockchain." text

      When I click the first "button" with "Advance" text
      Then I should see a "button" with "Advance contract" text

      When I fill in the "choice-input" input with "1"
      When I click the "button" with "Advance contract" text And sign the transaction with <wallet_name> wallet
      Then I should see the first "button" showing "Syncing" text
      And I should see the first "button" showing "Advance" text
      And I should see "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." text

    Examples:
      | wallet_name |
      | lace        |
      | nami        |


    Scenario Outline: Creating a timed-out contract with a wallet
      Given I configure my <wallet_name> wallet
      Given I am on the "home" page
      Then I should see a "heading" with "Choose a wallet" text

      When I authorize my <wallet_name> wallet
      Then I should see a "button" with "Create a contract" text

      When I click the "button" with "Create a contract" text
      And I generate the contract "TimedOutSimpleChoice" and write it to "/tmp/timed-out-choice.json"
      And I enter the contents of "/tmp/timed-out-choice.json" into the "contract-input" field

      When I click the "button" with "Submit contract" text And sign the transaction with <wallet_name> wallet
      Then I should see the first "button" showing "Syncing" text
      And I should see the first "button" showing "Advance" text
      And I should see "Successfully created and submitted the contract. Contract transaction awaits to be included in the blockchain." text

      When I click the first "button" with "Advance" text
      Then I should see a "button" with "Advance contract" text

      When I click the "button" with "Advance contract" text And sign the transaction with <wallet_name> wallet
      Then I should see the first "button" showing "Syncing" text
      And I should see the first "button" showing "Advance" text
      And I should see "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." text

    Examples:
      | wallet_name |
      | lace        |
      | nami        |




#    Scenario: Creating a notify contract with a Lace wallet
#      Given I am on the "home" page
#      When I authorize my "lace" wallet
#      Then I should see a "button" with "Create a contract" text
#
#      When I click the "button" with "Create a contract" text
#      And I generate the contract "TimeoutedOut" and put write it to "/tmp/timed-out.json"
#      And I enter the contents of "/tmp/timed-out.json" into the "contract-input" field
#
#      When I click the "button" with "Submit contract" text And sign the transaction
#      Then I should see a "button" with "Syncing" text
#      And I should see "Successfully created and submitted the contract. Contract transaction awaits to be included in the blockchain." text
