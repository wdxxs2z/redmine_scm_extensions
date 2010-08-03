# SCM Extensions plugin for Redmine
# Copyright (C) 2010 Arnaud MARTEL
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
require 'tmpdir'
require 'fileutils'

class ScmExtensionsController < ApplicationController
  unloadable

  layout 'base'
  before_filter :find_project, :except => [:show, :download]
  before_filter :find_repository, :only => [:show, :download]
  before_filter :authorize, :except => [:show, :download]

  helper :attachments
  include AttachmentsHelper

  def upload
    path = "root"
    path << "/#{params[:path]}" if (params[:path] && !params[:path].empty?)
    @scm_extensions = ScmExtensionsWrite.new(:path => path, :project => @project)

    if !request.get? && !request.xhr?
      @scm_extensions.path = params[:scm_extensions][:path]
      @scm_extensions.comments = params[:scm_extensions][:comments]
      @scm_extensions.recipients = params[:watchers]
      path = params[:scm_extensions][:path].sub(/^root/,'').sub(/^\//,'')
      attached = []
      if params[:attachments] && params[:attachments].is_a?(Hash)
        svnpath = path.empty? ? "/" : path

        if @project.repository.scm.respond_to?('scm_extensions_upload')
          ret = @project.repository.scm.scm_extensions_upload(@project, svnpath, params[:attachments], params[:scm_extensions][:comments], nil)
          case ret
          when 0
            flash[:notice] = l(:notice_scm_extensions_upload_success) if @scm_extensions.recipients
            @scm_extensions.deliver(params[:attachments]) 
          when 1
            flash[:error] = l(:error_scm_extensions_upload_failed)
          when 2
            flash[:error] = l(:error_scm_extensions_no_path_head)
          end
        end

      end
      redirect_to :controller => 'repositories', :action => 'show', :id => @project, :path => path.to_s.split(%r{[/\\]}).select {|p| !p.blank?}
      return
    end
  end

  def delete
    path = params[:path]
    parent = path
    svnpath = path.empty? ? "/" : path

    if @project.repository.scm.respond_to?('scm_extensions_delete')
      ret = @project.repository.scm.scm_extensions_delete(@project, svnpath, "deleted #{path}", nil)
      case ret
      when 0
        parent = File.dirname(svnpath).sub(/^\//,'')
        flash[:notice] = l(:notice_scm_extensions_delete_success)
      when 1
        flash[:error] = l(:error_scm_extensions_delete_failed)
      end
    end

    redirect_to :controller => 'repositories', :action => 'show', :id => @project, :path => parent.to_s.split(%r{[/\\]}).select {|p| !p.blank?}
    return
  end

  def mkdir
    path = "root"
    path << "/#{params[:path]}" if (params[:path] && !params[:path].empty?)
    @scm_extensions = ScmExtensionsWrite.new(:path => path, :project => @project)

    if !request.get? && !request.xhr?
      path = params[:scm_extensions][:path].sub(/^root/,'').sub(/^\//,'')
      foldername = params[:scm_extensions][:new_folder]
      svnpath = path.empty? ? "/" : path
      
      if @project.repository.scm.respond_to?('scm_extensions_mkdir')
        ret = @project.repository.scm.scm_extensions_mkdir(@project, File.join(svnpath, foldername), params[:scm_extensions][:comments], nil)
        case ret
        when 0
          flash[:notice] = l(:notice_scm_extensions_mkdir_success)
        when 1
          flash[:error] = l(:error_scm_extensions_mkdir_failed)
        end
      end
      redirect_to :controller => 'repositories', :action => 'show', :id => @project, :path => path.to_s.split(%r{[/\\]}).select {|p| !p.blank?}
      return
    end
  end

  def show
    return if !User.current.allowed_to?(:browse_repository, @project)
    @show_rev = params[:show_rev]
    @link_details = params[:link_details]
    @entries = @repository.entries(@path, @rev)
    if request.xhr?
      @entries ? render(:partial => 'scm_extensions/dir_list_content') : render(:nothing => true)
    end
  end

  def download
    return if !User.current.allowed_to?(:browse_repository, @project)
    @entry = @repository.entry(@path, @rev)
    (show_error_not_found; return) unless @entry

    # If the entry is a dir, show the browser
    (show; return) if @entry.is_dir?

    @content = @repository.cat(@path, @rev)
    (show_error_not_found; return) unless @content
    # Force the download
    send_data @content, :filename => @path.split('/').last, :disposition => "inline", :type => Redmine::MimeType.of(@path.split('/').last)
  end

  private

  def find_project
    @project = Project.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_repository
    @project = Project.find(params[:id])
    @repository = @project.repository
    (render_404; return false) unless @repository
    @path = params[:path].join('/') unless params[:path].nil?
    @path ||= ''
    @rev = params[:rev].blank? ? @repository.default_branch : params[:rev].strip
    @rev_to = params[:rev_to]
  rescue ActiveRecord::RecordNotFound
    render_404
  rescue InvalidRevisionParam
    show_error_not_found
  end

  def svn_target(repository, path = '')
    base = repository.url
    base = base.sub(/^.*:\/\/[^\/]*\//,"file:///svnroot/")
    uri = "#{base}/#{path}"
    uri = URI.escape(URI.escape(uri), '[]')
    shell_quote(uri.gsub(/[?<>\*]/, ''))
  end

  def gettmpdir(create = true)
    tmpdir = Dir.tmpdir
    t = Time.now.strftime("%Y%m%d")
    n = nil
    begin
      path = "#{tmpdir}/#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
      path << "-#{n}" if n
      Dir.mkdir(path, 0700)
      Dir.rmdir(path) unless create
    rescue Errno::EEXIST
      n ||= 0
      n += 1
      retry
    end

    if block_given?
      begin
        yield path
      ensure
        FileUtils.remove_entry_secure path if File.exist?(path)
        fname = "#{path}.txt"
        FileUtils.remove_entry_secure fname if File.exist?(fname)
      end
    else
      path
    end
  end

  def shell_quote(str)
    if Redmine::Platform.mswin?
      '"' + str.gsub(/"/, '\\"') + '"'
    else
      "'" + str.gsub(/'/, "'\"'\"'") + "'"
    end
  end

end