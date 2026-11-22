#import "GSAlbumManagement.h"
#import "GSPanel.h"
#import "GSCloudAlbumPicker.h"
#import "GSAlbumStatus.h"
#import "../Shared/GSLocalization.h"
#import "../Shared/IPCProtocol.h"

@interface GSAlbumManagement () <UITextFieldDelegate>
@property (nonatomic, copy) NSString *account;
@property (nonatomic, strong) NSMutableDictionary *draft;
@property (nonatomic, strong) NSDictionary *snapshot;
@property (nonatomic, copy) NSString *existingName;
@property (nonatomic, copy) NSString *draftAlbumName;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL diagnostics, busy, refreshing, draftDirty;
@property (nonatomic) NSUInteger generation;
@end

@implementation GSAlbumManagement
- (instancetype)initWithAccount:(NSString *)account {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
        _account = [account copy];
    return self;
}
+ (instancetype)diagnosticsForAccount:(NSString *)account {
    GSAlbumManagement *controller = [[self alloc] initWithAccount:account];
    controller.diagnostics = YES;
    return controller;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.diagnostics ? GSL(@"Album status") : GSL(@"Album destination");
    self.navigationItem.prompt = self.account;
    self.navigationItem.rightBarButtonItem = GSPanelDoneButton(self);
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                       [weakSelf refresh];
                                                   }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)message:(NSString *)text {
    if (self.presentedViewController)
        return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:self.title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GSL(@"OK")
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)refresh {
    if (self.refreshing || self.busy)
        return;
    self.refreshing = YES;
    NSUInteger generation = self.generation;
    NSString *account = self.account;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *snapshot =
            GSRequest(@{@"op" : @"album_status", @"account" : account}, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            if (generation != self.generation) {
                [self refresh];
                return;
            }
            if (!snapshot) {
                if (!self.snapshot)
                    [self message:GSL(@"Could not load album settings. Reconnect the account and "
                                      @"try again.")];
                return;
            }
            self.snapshot = snapshot;
            if (!self.draft || !self.draftDirty) {
                self.draft =
                    [snapshot[@"settings"] mutableCopy] ?: [NSMutableDictionary dictionary];
                BOOL existing = [self.draft[@"mode"] isEqual:@"existing"];
                self.draftAlbumName = existing ? @"" : (self.draft[@"name"] ?: @"");
                self.existingName = (existing || [snapshot[@"resolvedAlbumKey"] length])
                                        ? (self.draft[@"name"] ?: @"")
                                        : @"";
            }
            if (!self.nameField.isFirstResponder && !self.tableView.dragging &&
                !self.tableView.decelerating)
                [self.tableView reloadData];
        });
    });
}
- (void)send:(NSDictionary *)request resetDraft:(BOOL)reset {
    if (self.busy)
        return;
    self.busy = YES;
    self.generation++;
    [self.view endEditing:YES];
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *result = GSRequest(request, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!result)
                [self message:GSL(@"Album operation failed. Check account access and status before "
                                  @"retrying.")];
            else if (reset) {
                self.draft = nil;
                self.draftDirty = NO;
            }
            [self refresh];
        });
    });
}
- (NSString *)statusTitle {
    NSDictionary *titles = @{
        @"Disabled" : GSL(@"Disabled"),
        @"Waiting" : GSL(@"Waiting"),
        @"Uploading" : GSL(@"Uploading"),
        @"Adding to album" : GSL(@"Adding to album"),
        @"Completed" : GSL(@"Completed"),
        @"Failed" : GSL(@"Needs attention")
    };
    return titles[self.snapshot[@"status"]] ?: GSL(@"Loading…");
}
- (NSString *)reason {
    NSDictionary *reasons = @{
        @"album_access_denied" : GSL(@"Photos are uploaded, but this account cannot add them to "
                                     @"the destination album. Choose an album you can edit."),
        @"album_not_found_or_inaccessible" :
            GSL(@"The destination album was not found or is inaccessible. Choose another album for "
                @"the unfinished assignments."),
        @"album_invalid_request_or_id" : GSL(@"Google rejected the album request. Check the "
                                             @"selected album and account before trying again."),
        @"album_authorization_unavailable" :
            GSL(@"Reconnect the account to authorize album operations."),
        @"album_authorization_expired" :
            GSL(@"Reconnect the account to authorize album operations."),
        @"album_rate_limited" : GSL(@"Google requested a delay. Retrying with backoff."),
        @"create_outcome_unknown" :
            GSL(@"Google may have created the album, but the app did not receive confirmation. "
                @"Select the album that was actually created to continue without making another.")
    };
    return reasons[self.snapshot[@"error"]]
               ?: GSL(@"The last album request has no confirmed successful result. Check the album "
                      @"in Google Photos before retrying. The files do not need to be uploaded "
                      @"again.");
}
- (NSArray<NSDictionary *> *)issueRows {
    NSMutableArray *rows = [NSMutableArray array];
    if (!GSAlbumHasIssues(self.snapshot))
        return rows;
    if ([self.snapshot[@"error"] length])
        [rows addObject:@{@"title" : GSL(@"Reason"), @"detail" : [self reason]}];
    if ([self.snapshot[@"counts"][@"unresolved"] integerValue])
        [rows addObject:@{
            @"title" : GSL(@"Some items cannot be added automatically"),
            @"detail" : GSL(@"The app has no verified media ID for these uploaded items. Find them "
                            @"in Google Photos and add them to the album there. Retrying album "
                            @"work will not repair missing IDs.")
        }];
    NSSet *actions = GSAlbumDiagnosticActions(self.snapshot);
    if ([actions containsObject:@"retry"])
        [rows addObject:@{
            @"title" : GSL(@"Try adding to albums again"),
            @"detail" : GSL(
                @"Retry failed or unconfirmed album work. This does not upload the files again."),
            @"action" : @"retry"
        }];
    if ([actions containsObject:@"recover"])
        for (NSDictionary *target in self.snapshot[@"uncertainCreates"])
            [rows addObject:@{
                @"title" : GSL(@"Select the album that was created"),
                @"detail" :
                    [NSString stringWithFormat:
                                  @"%@\n%@", target[@"name"] ?: GSL(@"Album"),
                                  GSL(@"Choose the album Google may have created. This continues "
                                      @"the queue without creating a duplicate album.")],
                @"action" : @"recover",
                @"target" : target
            }];
    if ([actions containsObject:@"retarget"])
        for (NSDictionary *target in self.snapshot[@"repairableTargets"])
            [rows addObject:@{
                @"title" : GSL(@"Choose another album for unfinished items"),
                @"detail" : [NSString
                    stringWithFormat:
                        @"%@\n%@", [target[@"name"] length] ? target[@"name"] : GSL(@"Album"),
                        GSL(@"Move only rejected and unsent assignments. Confirmed and unconfirmed "
                            @"assignments stay in their original album.")],
                @"action" : @"retarget",
                @"target" : target
            }];
    return rows;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.diagnostics)
        return 4;
    if (section == 0)
        return 7;
    if (section == 1)
        return MAX([self issueRows].count, 1);
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.diagnostics)
        return section == 0 ? GSL(@"Album Management") : GSL(@"Saved destination");
    if (section == 0)
        return GSL(@"Album assignment status");
    if (section == 1)
        return GSL(@"Issues and next steps");
    return nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.diagnostics && section == 0)
        return GSL(@"Save applies to newly queued media. Existing tasks keep their original album. "
                   @"Turning this off pauses album tasks and leaves uploads running.");
    if (!self.diagnostics && section == 1)
        return GSL(@"Album assignment runs after uploads finish. Album errors do not require "
                   @"uploading the files again.");
    if (self.diagnostics && section == 0)
        return GSL(@"Accepted means Google acknowledged the request. Check the album in Google "
                   @"Photos to verify its contents.");
    if (self.diagnostics && section == 1 && ![self.snapshot[@"settings"][@"enabled"] boolValue])
        return GSL(@"Album assignment is paused. Enable it in Uploads to resume queued work.");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!self.diagnostics && path.section == 0) {
        BOOL existing = ![self.draft[@"mode"] isEqual:@"create"];
        if (path.row == 0) {
            cell.textLabel.text = GSL(@"Automatically add uploaded media to album");
            UISwitch *toggle = [UISwitch new];
            toggle.on = [self.draft[@"enabled"] boolValue];
            toggle.enabled = self.draft && !self.busy;
            toggle.accessibilityLabel = cell.textLabel.text;
            [toggle addTarget:self
                          action:@selector(toggle:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else if (path.row == 1) {
            UISegmentedControl *mode = [[UISegmentedControl alloc]
                initWithItems:@[ GSL(@"Existing Album"), GSL(@"Create New Album") ]];
            mode.selectedSegmentIndex = existing ? 0 : 1;
            mode.enabled = self.draft && !self.busy;
            [mode addTarget:self
                          action:@selector(modeChanged:)
                forControlEvents:UIControlEventValueChanged];
            mode.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:mode];
            [NSLayoutConstraint activateConstraints:@[
                [mode.leadingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [mode.trailingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [mode.topAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
                [mode.bottomAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor]
            ]];
        } else if (path.row == 2 && existing) {
            cell.textLabel.text = GSL(@"Choose album");
            cell.detailTextLabel.text =
                self.existingName.length
                    ? self.existingName
                    : ([self.draft[@"albumKey"] length] ? GSL(@"Selected album")
                                                        : GSL(@"Choose an existing album"));
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if (path.row == 2) {
            UITextField *field = [UITextField new];
            field.placeholder = GSL(@"New album name");
            field.text = self.draftAlbumName;
            field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            field.adjustsFontForContentSizeCategory = YES;
            field.delegate = self;
            field.accessibilityLabel = field.placeholder;
            field.returnKeyType = UIReturnKeyDone;
            field.enabled = self.draft != nil && !self.busy;
            [field addTarget:self
                          action:@selector(nameChanged:)
                forControlEvents:UIControlEventEditingChanged];
            field.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:field];
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [field.trailingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [field.topAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
                [field.bottomAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
                [field.heightAnchor constraintGreaterThanOrEqualToConstant:36]
            ]];
            self.nameField = field;
        } else {
            cell.textLabel.text = GSL(@"Save");
            cell.textLabel.textColor =
                self.busy ? UIColor.secondaryLabelColor : tableView.tintColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (!self.diagnostics) {
        NSDictionary *counts = self.snapshot[@"counts"];
        if (path.row == 0) {
            cell.textLabel.text = GSL(@"Saved destination");
            NSString *name = self.snapshot[@"settings"][@"name"];
            cell.detailTextLabel.text =
                name.length ? name
                            : ([self.snapshot[@"resolvedAlbumKey"] length] ? GSL(@"Selected album")
                                                                           : GSL(@"None"));
            if ([self.snapshot[@"settings"][@"mode"] isEqual:@"create"])
                cell.detailTextLabel.text = [NSString
                    stringWithFormat:@"%@\n%@", name ?: @"",
                                     [self.snapshot[@"resolvedAlbumKey"] length]
                                         ? GSL(@"Created. Future uploads reuse this album.")
                                         : GSL(@"Will be created after uploads finish.")];
        }
        if (path.row == 1) {
            cell.textLabel.text = GSL(@"Status");
            cell.detailTextLabel.text = [self statusTitle];
        }
        if (path.row == 2) {
            cell.textLabel.text = GSL(@"Album progress");
            cell.detailTextLabel.text = [NSString
                stringWithFormat:GSL(@"Accepted: %@ · Pending: %@"), counts[@"completed"] ?: @0,
                                 @([counts[@"pending"] integerValue] +
                                   [counts[@"adding"] integerValue])];
        }
        if (path.row == 3) {
            cell.textLabel.text = GSL(@"Album diagnostics");
            cell.detailTextLabel.text = GSAlbumHasIssues(self.snapshot)
                                            ? GSL(@"Some uploaded media still need album "
                                                  @"assignment. View details and next steps.")
                                            : GSL(@"View details or export a diagnostic report.");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (path.section == 0) {
        NSArray *titles = @[
            GSL(@"Status"), GSL(@"Waiting to add"), GSL(@"Being added"), GSL(@"Accepted by Google"),
            GSL(@"Could not add"), GSL(@"Result not confirmed"), GSL(@"Missing media ID")
        ];
        NSArray *keys =
            @[ @"", @"pending", @"adding", @"completed", @"failed", @"uncertain", @"unresolved" ];
        cell.textLabel.text = titles[path.row];
        cell.detailTextLabel.text =
            path.row == 0 ? [self statusTitle]
                          : [self.snapshot[@"counts"][keys[path.row]] ?: @0 description];
    } else if (path.section == 1) {
        if (![self issueRows].count) {
            cell.textLabel.text =
                self.snapshot ? GSL(@"No album issues need action") : GSL(@"Loading…");
            return cell;
        }
        NSDictionary *row = [self issueRows][path.row];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"detail"];
        if (row[@"action"]) {
            cell.textLabel.textColor = tableView.tintColor;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    }
    return cell;
}
- (void)toggle:(UISwitch *)sender {
    self.draft[@"enabled"] = @(sender.on);
    self.draftDirty = YES;
}
- (void)modeChanged:(UISegmentedControl *)sender {
    self.draft[@"mode"] = sender.selectedSegmentIndex ? @"create" : @"existing";
    self.draftDirty = YES;
    [self.view endEditing:YES];
    [self.tableView reloadData];
}
- (void)nameChanged:(UITextField *)sender {
    self.draftAlbumName = sender.text ?: @"";
    self.draftDirty = YES;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
- (void)choose:(void (^)(NSString *, NSString *))selection {
    GSCloudAlbumPicker *picker =
        [[GSCloudAlbumPicker alloc] initWithAccount:self.account
                                         selectedID:self.draft[@"albumKey"] ?: @""
                                          selection:selection];
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)save {
    BOOL existing = ![self.draft[@"mode"] isEqual:@"create"];
    NSString *name =
        [self.draftAlbumName
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            ?: @"";
    if ([self.draft[@"enabled"] boolValue]) {
        if (existing && ![self.draft[@"albumKey"] length]) {
            [self message:GSL(@"Choose an album before saving.")];
            return;
        }
        NSMutableCharacterSet *invalid =
            [NSMutableCharacterSet characterSetWithCharactersInString:@"\n\r"];
        [invalid addCharactersInRange:NSMakeRange(0, 1)];
        if (!existing &&
            (!name.length || [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 200 ||
             [name rangeOfCharacterFromSet:invalid].location != NSNotFound)) {
            [self message:GSL(@"Enter a short album name without line breaks.")];
            return;
        }
    }
    NSMutableDictionary *settings = [self.draft mutableCopy];
    settings[@"name"] = existing ? (self.existingName ?: @"") : name;
    [self send:@{@"op" : @"album_configure", @"account" : self.account, @"album" : settings}
        resetDraft:YES];
}
- (void)confirm:(NSString *)title message:(NSString *)message action:(void (^)(void))action {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Confirm")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
                                                action();
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)retry {
    void (^send)(BOOL) = ^(BOOL confirm) {
        [self send:@{@"op" : @"album_retry", @"account" : self.account, @"confirm" : @(confirm)}
            resetDraft:NO];
    };
    if ([self.snapshot[@"counts"][@"uncertain"] integerValue])
        [self
            confirm:GSL(@"Check the album before retrying")
            message:
                GSL(@"Google may already have added some items. Check the album first. Continuing "
                    @"sends the unconfirmed assignments again; it does not upload files again.")
             action:^{
                 send(YES);
             }];
    else
        send(NO);
}
- (void)actOnTarget:(NSDictionary *)target recover:(BOOL)recover {
    __weak typeof(self) weakSelf = self;
    [self choose:^(NSString *key, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self)
            return;
        NSString *message = recover
                                ? GSL(@"Confirm this is the album that was actually created. "
                                      @"Another album will not be created.")
                                : GSL(@"Only failed and unsent tasks move to this album. Confirmed "
                                      @"and uncertain assignments keep their original target.");
        message = [NSString
            stringWithFormat:@"%@\n\n%@", name.length ? name : GSL(@"Selected album"), message];
        [self confirm:recover ? GSL(@"Use this album to continue?")
                              : GSL(@"Move unfinished assignments to this album?")
              message:message
               action:^{
                   [self send:@{
                       @"op" : recover ? @"album_resolve" : @"album_retarget",
                       @"account" : self.account,
                       @"id" : target[@"targetID"],
                       @"album" : @{@"albumKey" : key}
                   }
                       resetDraft:NO];
               }];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy || !self.snapshot)
        return;
    if (!self.diagnostics) {
        if (path.section == 0 && path.row == 2 && ![self.draft[@"mode"] isEqual:@"create"]) {
            __weak typeof(self) weakSelf = self;
            [self choose:^(NSString *key, NSString *name) {
                typeof(self) self = weakSelf;
                if (!self)
                    return;
                self.draft[@"albumKey"] = key;
                self.existingName = name ?: @"";
                self.draftDirty = YES;
                [self.tableView reloadData];
            }];
        } else if (path.section == 0 && path.row == 3)
            [self save];
        else if (path.section == 1 && path.row == 3)
            [self.navigationController
                pushViewController:[GSAlbumManagement diagnosticsForAccount:self.account]
                          animated:YES];
    } else if (path.section == 1) {
        if (![self issueRows].count)
            return;
        NSDictionary *row = [self issueRows][path.row];
        NSString *action = row[@"action"];
        if ([action isEqual:@"retry"])
            [self retry];
        else if ([action isEqual:@"recover"] || [action isEqual:@"retarget"])
            [self actOnTarget:row[@"target"] recover:[action isEqual:@"recover"]];
    }
}
@end
