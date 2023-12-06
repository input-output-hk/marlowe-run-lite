@smoke
@regression

@open-contract-via-url
Feature: As a user, I would like open a contract via url for services like marlowe playground

    As a user who created a contract in marlowe playground
    I would like to open this contract via url
    So that I can quickly run a contract that I created on Marlowe Playground

    Scenario Outline: As a user I expect to be able to choose the <wallet_name> wallet
      Given I use alice <wallet_name> browser
      And I am on the "close contract" page
      Then I should see a "heading" with "Choose a wallet" text

      When I authorize the app
      Then I should see a "tab" with "Source graph" text
      And I should see a "tab" with "Code" text
      And I should see a "button" with "Upload JSON" text
      And I should see a "button" with "Submit contract" text
      And I should see a "button" with "Back to contract list" text
    Examples:
      | wallet_name |
      | lace        |
      | nami        |

