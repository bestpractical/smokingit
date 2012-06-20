var all_statuses = "broken errors failing todo passing parsefail testing queued untested";
jQuery(function(){
    jQuery(pubsub).bind("message.test_progress", function (event, d) {
        jQuery(".commit."+d.sha+" .okbox.config-"+d.config)
            .removeClass(all_statuses)
            .addClass(d.raw_status)
            .attr("title",d.status)
            .text( d.percent );
        jQuery(".commit."+d.sha+".config-"+d.config)
            .removeClass(all_statuses)
            .addClass(d.raw_status);
        jQuery(".commit."+d.sha+".config-"+d.config+" .sha")
            .attr("title",d.status);
        if ( d.raw_status != "testing" )
            jQuery(".commit."+d.sha+" .okbox.config-"+d.config)
                .html( "&nbsp" );
    });

    jQuery(pubsub).bind("message.commit_status", function (event, d) {
        jQuery(".biglist .commit."+d.sha)
            .removeClass(all_statuses)
            .addClass(d.raw_status);
        jQuery("#branch-list ."+d.sha)
            .removeClass(all_statuses)
            .addClass(d.raw_status);
        jQuery(".biglist .commit."+d.sha+" .testme")
            .removeClass("testme")
            .addClass("retestme");
    });
});
